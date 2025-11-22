/* SPDX-FileCopyrightText: 2025 OpenWiFi Project
 * SPDX-License-Identifier: AGPL-3.0-only
 */

/**
 * @file enhanced_xpu_drv.c
 * @brief Linux Kernel Driver for Enhanced XPU Hardware
 *
 * This driver provides userspace access to the Enhanced XPU hardware module
 * for WiFi monitoring, frame injection, and Remote ID functionality.
 *
 * Features:
 * - Character device interface (/dev/enhanced_xpu)
 * - IOCTL interface for configuration
 * - DMA support for RX captured packets
 * - DMA support for TX injected frames
 * - Integration with mac80211 framework
 *
 * @author OpenWiFi Team
 * @date 2025-11-22
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/fs.h>
#include <linux/device.h>
#include <linux/cdev.h>
#include <linux/platform_device.h>
#include <linux/of.h>
#include <linux/of_address.h>
#include <linux/io.h>
#include <linux/dma-mapping.h>
#include <linux/interrupt.h>
#include <linux/wait.h>
#include <linux/poll.h>
#include <linux/uaccess.h>
#include <linux/slab.h>
#include <linux/circ_buf.h>
#include "enhanced_xpu_ioctl.h"

/* ========================================================================
 * Hardware Register Definitions
 * ======================================================================== */

/* AXI Base Address (from device tree) */
#define XPU_REG_CONTROL         0x00  /* Control register */
#define XPU_REG_STATUS          0x04  /* Status register */
#define XPU_REG_IRQ_ENABLE      0x08  /* Interrupt enable */
#define XPU_REG_IRQ_STATUS      0x0C  /* Interrupt status */
#define XPU_REG_FILTER_CTRL     0x10  /* Packet filter control */
#define XPU_REG_FILTER_MAC0     0x14  /* MAC filter address 0 */
#define XPU_REG_FILTER_MAC1     0x18  /* MAC filter address 1 */
#define XPU_REG_FILTER_TYPE     0x1C  /* Frame type filter */
#define XPU_REG_RX_DMA_ADDR     0x20  /* RX DMA buffer address */
#define XPU_REG_RX_DMA_SIZE     0x24  /* RX DMA buffer size */
#define XPU_REG_RX_PKT_COUNT    0x28  /* RX packet count */
#define XPU_REG_TX_DMA_ADDR     0x30  /* TX DMA buffer address */
#define XPU_REG_TX_DMA_SIZE     0x34  /* TX DMA buffer size */
#define XPU_REG_TX_CTRL         0x38  /* TX control */
#define XPU_REG_STATS_RX        0x40  /* RX statistics */
#define XPU_REG_STATS_TX        0x44  /* TX statistics */
#define XPU_REG_STATS_DROP      0x48  /* Drop statistics */
#define XPU_REG_REMOTE_ID_CTRL  0x50  /* Remote ID control */

/* Control register bits */
#define XPU_CTRL_ENABLE         BIT(0)
#define XPU_CTRL_MONITOR_MODE   BIT(1)
#define XPU_CTRL_INJECT_MODE    BIT(2)
#define XPU_CTRL_REMOTE_ID_EN   BIT(3)
#define XPU_CTRL_PROMISCUOUS    BIT(4)
#define XPU_CTRL_RESET          BIT(31)

/* Status register bits */
#define XPU_STATUS_READY        BIT(0)
#define XPU_STATUS_RX_BUSY      BIT(1)
#define XPU_STATUS_TX_BUSY      BIT(2)
#define XPU_STATUS_ERROR        BIT(31)

/* Interrupt bits */
#define XPU_IRQ_RX_DONE         BIT(0)
#define XPU_IRQ_TX_DONE         BIT(1)
#define XPU_IRQ_RX_OVERFLOW     BIT(2)
#define XPU_IRQ_ERROR           BIT(3)

/* DMA buffer sizes */
#define XPU_RX_DMA_SIZE         (64 * 1024)   /* 64KB RX buffer */
#define XPU_TX_DMA_SIZE         (16 * 1024)   /* 16KB TX buffer */
#define XPU_MAX_PACKET_SIZE     2048          /* Max packet size */

/* ========================================================================
 * Driver Data Structures
 * ======================================================================== */

/**
 * @brief DMA buffer descriptor
 */
struct xpu_dma_buffer {
    void *cpu_addr;          /* CPU virtual address */
    dma_addr_t dma_addr;     /* DMA physical address */
    size_t size;             /* Buffer size */
    unsigned int head;       /* Circular buffer head */
    unsigned int tail;       /* Circular buffer tail */
};

/**
 * @brief Packet capture queue entry
 */
struct xpu_packet {
    struct list_head list;
    size_t len;
    u8 data[];
};

/**
 * @brief Enhanced XPU device context
 */
struct enhanced_xpu_dev {
    /* Device infrastructure */
    struct platform_device *pdev;
    struct device *device;
    struct cdev cdev;
    dev_t devt;
    struct class *class;

    /* Hardware resources */
    void __iomem *regs;
    int irq;

    /* DMA buffers */
    struct xpu_dma_buffer rx_dma;
    struct xpu_dma_buffer tx_dma;

    /* Packet capture */
    struct list_head rx_queue;
    spinlock_t rx_lock;
    wait_queue_head_t rx_wait;
    unsigned int rx_queue_len;
    unsigned int rx_queue_max;

    /* TX injection */
    spinlock_t tx_lock;
    wait_queue_head_t tx_wait;
    bool tx_busy;

    /* Configuration */
    struct xpu_config config;
    struct xpu_filter_config filter;

    /* Statistics */
    struct xpu_stats stats;

    /* State */
    bool monitor_mode;
    bool inject_mode;
    bool remote_id_enabled;
    atomic_t open_count;
};

/* Global device pointer */
static struct enhanced_xpu_dev *xpu_dev;

/* ========================================================================
 * Hardware Access Functions
 * ======================================================================== */

static inline u32 xpu_read_reg(struct enhanced_xpu_dev *dev, u32 offset)
{
    return ioread32(dev->regs + offset);
}

static inline void xpu_write_reg(struct enhanced_xpu_dev *dev,
                                  u32 offset, u32 value)
{
    iowrite32(value, dev->regs + offset);
}

/**
 * @brief Reset the XPU hardware
 */
static int xpu_hw_reset(struct enhanced_xpu_dev *dev)
{
    u32 timeout = 1000;

    /* Assert reset */
    xpu_write_reg(dev, XPU_REG_CONTROL, XPU_CTRL_RESET);
    msleep(10);

    /* Deassert reset */
    xpu_write_reg(dev, XPU_REG_CONTROL, 0);
    msleep(10);

    /* Wait for ready */
    while (timeout--) {
        if (xpu_read_reg(dev, XPU_REG_STATUS) & XPU_STATUS_READY)
            return 0;
        usleep_range(100, 200);
    }

    dev_err(dev->device, "Hardware reset timeout\n");
    return -ETIMEDOUT;
}

/**
 * @brief Configure packet filters
 */
static int xpu_hw_set_filter(struct enhanced_xpu_dev *dev,
                              struct xpu_filter_config *filter)
{
    u32 filter_ctrl = 0;

    /* MAC address filtering */
    if (filter->flags & XPU_FILTER_MAC_ADDR) {
        u32 mac0 = (filter->mac_addr[3] << 24) |
                   (filter->mac_addr[2] << 16) |
                   (filter->mac_addr[1] << 8) |
                   filter->mac_addr[0];
        u32 mac1 = (filter->mac_addr[5] << 8) |
                   filter->mac_addr[4];

        xpu_write_reg(dev, XPU_REG_FILTER_MAC0, mac0);
        xpu_write_reg(dev, XPU_REG_FILTER_MAC1, mac1);
        filter_ctrl |= BIT(0);
    }

    /* Frame type filtering */
    if (filter->flags & XPU_FILTER_FRAME_TYPE) {
        xpu_write_reg(dev, XPU_REG_FILTER_TYPE, filter->frame_type_mask);
        filter_ctrl |= BIT(1);
    }

    /* BSSID filtering */
    if (filter->flags & XPU_FILTER_BSSID) {
        filter_ctrl |= BIT(2);
    }

    xpu_write_reg(dev, XPU_REG_FILTER_CTRL, filter_ctrl);
    memcpy(&dev->filter, filter, sizeof(*filter));

    return 0;
}

/**
 * @brief Enable/disable monitor mode
 */
static int xpu_hw_set_monitor_mode(struct enhanced_xpu_dev *dev, bool enable)
{
    u32 ctrl = xpu_read_reg(dev, XPU_REG_CONTROL);

    if (enable) {
        ctrl |= XPU_CTRL_MONITOR_MODE;
        ctrl |= XPU_CTRL_PROMISCUOUS;
        dev->monitor_mode = true;
    } else {
        ctrl &= ~XPU_CTRL_MONITOR_MODE;
        ctrl &= ~XPU_CTRL_PROMISCUOUS;
        dev->monitor_mode = false;
    }

    xpu_write_reg(dev, XPU_REG_CONTROL, ctrl);
    return 0;
}

/**
 * @brief Enable/disable inject mode
 */
static int xpu_hw_set_inject_mode(struct enhanced_xpu_dev *dev, bool enable)
{
    u32 ctrl = xpu_read_reg(dev, XPU_REG_CONTROL);

    if (enable) {
        ctrl |= XPU_CTRL_INJECT_MODE;
        dev->inject_mode = true;
    } else {
        ctrl &= ~XPU_CTRL_INJECT_MODE;
        dev->inject_mode = false;
    }

    xpu_write_reg(dev, XPU_REG_CONTROL, ctrl);
    return 0;
}

/**
 * @brief Setup DMA buffers
 */
static int xpu_setup_dma(struct enhanced_xpu_dev *dev)
{
    struct device *dma_dev = &dev->pdev->dev;

    /* Allocate RX DMA buffer */
    dev->rx_dma.size = XPU_RX_DMA_SIZE;
    dev->rx_dma.cpu_addr = dma_alloc_coherent(dma_dev,
                                               dev->rx_dma.size,
                                               &dev->rx_dma.dma_addr,
                                               GFP_KERNEL);
    if (!dev->rx_dma.cpu_addr) {
        dev_err(dev->device, "Failed to allocate RX DMA buffer\n");
        return -ENOMEM;
    }

    /* Allocate TX DMA buffer */
    dev->tx_dma.size = XPU_TX_DMA_SIZE;
    dev->tx_dma.cpu_addr = dma_alloc_coherent(dma_dev,
                                               dev->tx_dma.size,
                                               &dev->tx_dma.dma_addr,
                                               GFP_KERNEL);
    if (!dev->tx_dma.cpu_addr) {
        dev_err(dev->device, "Failed to allocate TX DMA buffer\n");
        dma_free_coherent(dma_dev, dev->rx_dma.size,
                         dev->rx_dma.cpu_addr, dev->rx_dma.dma_addr);
        return -ENOMEM;
    }

    /* Configure hardware DMA addresses */
    xpu_write_reg(dev, XPU_REG_RX_DMA_ADDR, dev->rx_dma.dma_addr);
    xpu_write_reg(dev, XPU_REG_RX_DMA_SIZE, dev->rx_dma.size);
    xpu_write_reg(dev, XPU_REG_TX_DMA_ADDR, dev->tx_dma.dma_addr);
    xpu_write_reg(dev, XPU_REG_TX_DMA_SIZE, dev->tx_dma.size);

    dev_info(dev->device, "DMA buffers: RX=%pad (%zu bytes), TX=%pad (%zu bytes)\n",
             &dev->rx_dma.dma_addr, dev->rx_dma.size,
             &dev->tx_dma.dma_addr, dev->tx_dma.size);

    return 0;
}

/**
 * @brief Free DMA buffers
 */
static void xpu_free_dma(struct enhanced_xpu_dev *dev)
{
    struct device *dma_dev = &dev->pdev->dev;

    if (dev->rx_dma.cpu_addr) {
        dma_free_coherent(dma_dev, dev->rx_dma.size,
                         dev->rx_dma.cpu_addr, dev->rx_dma.dma_addr);
        dev->rx_dma.cpu_addr = NULL;
    }

    if (dev->tx_dma.cpu_addr) {
        dma_free_coherent(dma_dev, dev->tx_dma.size,
                         dev->tx_dma.cpu_addr, dev->tx_dma.dma_addr);
        dev->tx_dma.cpu_addr = NULL;
    }
}

/* ========================================================================
 * Interrupt Handler
 * ======================================================================== */

static irqreturn_t xpu_irq_handler(int irq, void *data)
{
    struct enhanced_xpu_dev *dev = data;
    u32 irq_status;
    unsigned long flags;

    irq_status = xpu_read_reg(dev, XPU_REG_IRQ_STATUS);
    if (!irq_status)
        return IRQ_NONE;

    /* RX packet received */
    if (irq_status & XPU_IRQ_RX_DONE) {
        spin_lock_irqsave(&dev->rx_lock, flags);

        /* Process received packets from DMA buffer */
        /* TODO: Parse DMA buffer and queue packets */
        dev->stats.rx_packets++;

        spin_unlock_irqrestore(&dev->rx_lock, flags);
        wake_up_interruptible(&dev->rx_wait);
    }

    /* TX complete */
    if (irq_status & XPU_IRQ_TX_DONE) {
        spin_lock_irqsave(&dev->tx_lock, flags);
        dev->tx_busy = false;
        dev->stats.tx_packets++;
        spin_unlock_irqrestore(&dev->tx_lock, flags);
        wake_up_interruptible(&dev->tx_wait);
    }

    /* RX overflow */
    if (irq_status & XPU_IRQ_RX_OVERFLOW) {
        dev->stats.rx_dropped++;
        dev_warn(dev->device, "RX overflow\n");
    }

    /* Error */
    if (irq_status & XPU_IRQ_ERROR) {
        dev->stats.errors++;
        dev_err(dev->device, "Hardware error\n");
    }

    /* Clear interrupts */
    xpu_write_reg(dev, XPU_REG_IRQ_STATUS, irq_status);

    return IRQ_HANDLED;
}

/* ========================================================================
 * Character Device Operations
 * ======================================================================== */

static int xpu_open(struct inode *inode, struct file *filp)
{
    struct enhanced_xpu_dev *dev = container_of(inode->i_cdev,
                                                 struct enhanced_xpu_dev,
                                                 cdev);

    if (atomic_inc_return(&dev->open_count) > 1) {
        atomic_dec(&dev->open_count);
        return -EBUSY;  /* Only one process can open */
    }

    filp->private_data = dev;

    /* Enable hardware */
    xpu_write_reg(dev, XPU_REG_CONTROL, XPU_CTRL_ENABLE);

    /* Enable interrupts */
    xpu_write_reg(dev, XPU_REG_IRQ_ENABLE,
                  XPU_IRQ_RX_DONE | XPU_IRQ_TX_DONE |
                  XPU_IRQ_RX_OVERFLOW | XPU_IRQ_ERROR);

    return 0;
}

static int xpu_release(struct inode *inode, struct file *filp)
{
    struct enhanced_xpu_dev *dev = filp->private_data;
    struct xpu_packet *pkt, *tmp;

    /* Disable hardware */
    xpu_write_reg(dev, XPU_REG_CONTROL, 0);
    xpu_write_reg(dev, XPU_REG_IRQ_ENABLE, 0);

    /* Flush RX queue */
    list_for_each_entry_safe(pkt, tmp, &dev->rx_queue, list) {
        list_del(&pkt->list);
        kfree(pkt);
    }
    dev->rx_queue_len = 0;

    atomic_dec(&dev->open_count);
    return 0;
}

static ssize_t xpu_read(struct file *filp, char __user *buf,
                        size_t count, loff_t *ppos)
{
    struct enhanced_xpu_dev *dev = filp->private_data;
    struct xpu_packet *pkt;
    unsigned long flags;
    ssize_t ret;

    /* Wait for packets */
    if (filp->f_flags & O_NONBLOCK) {
        if (list_empty(&dev->rx_queue))
            return -EAGAIN;
    } else {
        ret = wait_event_interruptible(dev->rx_wait,
                                       !list_empty(&dev->rx_queue));
        if (ret)
            return ret;
    }

    spin_lock_irqsave(&dev->rx_lock, flags);

    if (list_empty(&dev->rx_queue)) {
        spin_unlock_irqrestore(&dev->rx_lock, flags);
        return -EAGAIN;
    }

    /* Get first packet */
    pkt = list_first_entry(&dev->rx_queue, struct xpu_packet, list);

    if (count < pkt->len) {
        spin_unlock_irqrestore(&dev->rx_lock, flags);
        return -EINVAL;
    }

    list_del(&pkt->list);
    dev->rx_queue_len--;

    spin_unlock_irqrestore(&dev->rx_lock, flags);

    /* Copy to userspace */
    if (copy_to_user(buf, pkt->data, pkt->len)) {
        kfree(pkt);
        return -EFAULT;
    }

    ret = pkt->len;
    kfree(pkt);

    return ret;
}

static ssize_t xpu_write(struct file *filp, const char __user *buf,
                         size_t count, loff_t *ppos)
{
    struct enhanced_xpu_dev *dev = filp->private_data;
    unsigned long flags;
    int ret;

    if (!dev->inject_mode)
        return -EPERM;

    if (count > XPU_MAX_PACKET_SIZE)
        return -EINVAL;

    /* Wait for TX ready */
    spin_lock_irqsave(&dev->tx_lock, flags);
    if (dev->tx_busy) {
        spin_unlock_irqrestore(&dev->tx_lock, flags);

        if (filp->f_flags & O_NONBLOCK)
            return -EAGAIN;

        ret = wait_event_interruptible(dev->tx_wait, !dev->tx_busy);
        if (ret)
            return ret;

        spin_lock_irqsave(&dev->tx_lock, flags);
    }

    dev->tx_busy = true;
    spin_unlock_irqrestore(&dev->tx_lock, flags);

    /* Copy from userspace to DMA buffer */
    if (copy_from_user(dev->tx_dma.cpu_addr, buf, count)) {
        dev->tx_busy = false;
        return -EFAULT;
    }

    /* Trigger TX */
    xpu_write_reg(dev, XPU_REG_TX_DMA_SIZE, count);
    xpu_write_reg(dev, XPU_REG_TX_CTRL, 1);

    return count;
}

static long xpu_ioctl(struct file *filp, unsigned int cmd, unsigned long arg)
{
    struct enhanced_xpu_dev *dev = filp->private_data;
    void __user *argp = (void __user *)arg;
    int ret = 0;

    switch (cmd) {
    case XPU_IOC_SET_CONFIG: {
        struct xpu_config config;
        if (copy_from_user(&config, argp, sizeof(config)))
            return -EFAULT;
        memcpy(&dev->config, &config, sizeof(config));
        break;
    }

    case XPU_IOC_GET_CONFIG:
        if (copy_to_user(argp, &dev->config, sizeof(dev->config)))
            return -EFAULT;
        break;

    case XPU_IOC_SET_MONITOR:
        ret = xpu_hw_set_monitor_mode(dev, arg ? true : false);
        break;

    case XPU_IOC_SET_INJECT:
        ret = xpu_hw_set_inject_mode(dev, arg ? true : false);
        break;

    case XPU_IOC_SET_FILTER: {
        struct xpu_filter_config filter;
        if (copy_from_user(&filter, argp, sizeof(filter)))
            return -EFAULT;
        ret = xpu_hw_set_filter(dev, &filter);
        break;
    }

    case XPU_IOC_GET_STATS:
        /* Update hardware stats */
        dev->stats.rx_bytes = xpu_read_reg(dev, XPU_REG_STATS_RX);
        dev->stats.tx_bytes = xpu_read_reg(dev, XPU_REG_STATS_TX);
        dev->stats.rx_dropped = xpu_read_reg(dev, XPU_REG_STATS_DROP);

        if (copy_to_user(argp, &dev->stats, sizeof(dev->stats)))
            return -EFAULT;
        break;

    case XPU_IOC_RESET:
        ret = xpu_hw_reset(dev);
        break;

    default:
        return -ENOTTY;
    }

    return ret;
}

static unsigned int xpu_poll(struct file *filp, poll_table *wait)
{
    struct enhanced_xpu_dev *dev = filp->private_data;
    unsigned int mask = 0;

    poll_wait(filp, &dev->rx_wait, wait);
    poll_wait(filp, &dev->tx_wait, wait);

    if (!list_empty(&dev->rx_queue))
        mask |= POLLIN | POLLRDNORM;

    if (!dev->tx_busy)
        mask |= POLLOUT | POLLWRNORM;

    return mask;
}

static const struct file_operations xpu_fops = {
    .owner = THIS_MODULE,
    .open = xpu_open,
    .release = xpu_release,
    .read = xpu_read,
    .write = xpu_write,
    .unlocked_ioctl = xpu_ioctl,
    .poll = xpu_poll,
};

/* ========================================================================
 * Platform Driver
 * ======================================================================== */

static int enhanced_xpu_probe(struct platform_device *pdev)
{
    struct resource *res;
    int ret;

    dev_info(&pdev->dev, "Probing Enhanced XPU driver\n");

    /* Allocate device structure */
    xpu_dev = devm_kzalloc(&pdev->dev, sizeof(*xpu_dev), GFP_KERNEL);
    if (!xpu_dev)
        return -ENOMEM;

    xpu_dev->pdev = pdev;
    platform_set_drvdata(pdev, xpu_dev);

    /* Get MMIO resources */
    res = platform_get_resource(pdev, IORESOURCE_MEM, 0);
    xpu_dev->regs = devm_ioremap_resource(&pdev->dev, res);
    if (IS_ERR(xpu_dev->regs))
        return PTR_ERR(xpu_dev->regs);

    /* Get IRQ */
    xpu_dev->irq = platform_get_irq(pdev, 0);
    if (xpu_dev->irq < 0)
        return xpu_dev->irq;

    /* Initialize data structures */
    INIT_LIST_HEAD(&xpu_dev->rx_queue);
    spin_lock_init(&xpu_dev->rx_lock);
    spin_lock_init(&xpu_dev->tx_lock);
    init_waitqueue_head(&xpu_dev->rx_wait);
    init_waitqueue_head(&xpu_dev->tx_wait);
    xpu_dev->rx_queue_max = 256;
    atomic_set(&xpu_dev->open_count, 0);

    /* Reset hardware */
    ret = xpu_hw_reset(xpu_dev);
    if (ret)
        return ret;

    /* Setup DMA */
    ret = xpu_setup_dma(xpu_dev);
    if (ret)
        return ret;

    /* Request IRQ */
    ret = devm_request_irq(&pdev->dev, xpu_dev->irq, xpu_irq_handler,
                          0, "enhanced_xpu", xpu_dev);
    if (ret) {
        dev_err(&pdev->dev, "Failed to request IRQ %d\n", xpu_dev->irq);
        goto err_free_dma;
    }

    /* Create character device */
    ret = alloc_chrdev_region(&xpu_dev->devt, 0, 1, "enhanced_xpu");
    if (ret) {
        dev_err(&pdev->dev, "Failed to allocate chrdev region\n");
        goto err_free_dma;
    }

    cdev_init(&xpu_dev->cdev, &xpu_fops);
    xpu_dev->cdev.owner = THIS_MODULE;

    ret = cdev_add(&xpu_dev->cdev, xpu_dev->devt, 1);
    if (ret) {
        dev_err(&pdev->dev, "Failed to add cdev\n");
        goto err_unregister_chrdev;
    }

    /* Create device class */
    xpu_dev->class = class_create(THIS_MODULE, "enhanced_xpu");
    if (IS_ERR(xpu_dev->class)) {
        ret = PTR_ERR(xpu_dev->class);
        goto err_del_cdev;
    }

    /* Create device node */
    xpu_dev->device = device_create(xpu_dev->class, &pdev->dev,
                                    xpu_dev->devt, NULL, "enhanced_xpu");
    if (IS_ERR(xpu_dev->device)) {
        ret = PTR_ERR(xpu_dev->device);
        goto err_destroy_class;
    }

    dev_info(&pdev->dev, "Enhanced XPU driver loaded successfully\n");
    dev_info(&pdev->dev, "Character device: /dev/enhanced_xpu\n");

    return 0;

err_destroy_class:
    class_destroy(xpu_dev->class);
err_del_cdev:
    cdev_del(&xpu_dev->cdev);
err_unregister_chrdev:
    unregister_chrdev_region(xpu_dev->devt, 1);
err_free_dma:
    xpu_free_dma(xpu_dev);
    return ret;
}

static int enhanced_xpu_remove(struct platform_device *pdev)
{
    struct enhanced_xpu_dev *dev = platform_get_drvdata(pdev);

    device_destroy(dev->class, dev->devt);
    class_destroy(dev->class);
    cdev_del(&dev->cdev);
    unregister_chrdev_region(dev->devt, 1);
    xpu_free_dma(dev);

    dev_info(&pdev->dev, "Enhanced XPU driver removed\n");
    return 0;
}

static const struct of_device_id enhanced_xpu_of_match[] = {
    { .compatible = "openwifi,enhanced-xpu-1.0", },
    { }
};
MODULE_DEVICE_TABLE(of, enhanced_xpu_of_match);

static struct platform_driver enhanced_xpu_driver = {
    .probe = enhanced_xpu_probe,
    .remove = enhanced_xpu_remove,
    .driver = {
        .name = "enhanced_xpu",
        .of_match_table = enhanced_xpu_of_match,
    },
};

module_platform_driver(enhanced_xpu_driver);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("OpenWiFi Team");
MODULE_DESCRIPTION("Enhanced XPU Driver for WiFi Monitoring and Injection");
MODULE_VERSION("1.0");
