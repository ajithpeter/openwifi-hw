#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2025 OpenWiFi Project
# SPDX-License-Identifier: AGPL-3.0-only

"""
Setup script for Enhanced XPU Python bindings.
"""

from setuptools import setup, find_packages

with open("README.md", "r", encoding="utf-8") as f:
    long_description = f.read()

setup(
    name="enhanced-xpu",
    version="1.0.0",
    author="OpenWiFi Team",
    author_email="info@openwifi-project.org",
    description="Python bindings for Enhanced XPU WiFi monitoring and Remote ID",
    long_description=long_description,
    long_description_content_type="text/markdown",
    url="https://github.com/open-sdr/openwifi-hw",
    py_modules=["enhanced_xpu"],
    python_requires=">=3.6",
    classifiers=[
        "Development Status :: 4 - Beta",
        "Intended Audience :: Developers",
        "Intended Audience :: Science/Research",
        "Topic :: System :: Hardware :: Universal Serial Bus (USB) :: Wireless Controller",
        "Topic :: Scientific/Engineering",
        "License :: OSI Approved :: GNU Affero General Public License v3",
        "Programming Language :: Python :: 3",
        "Programming Language :: Python :: 3.6",
        "Programming Language :: Python :: 3.7",
        "Programming Language :: Python :: 3.8",
        "Programming Language :: Python :: 3.9",
        "Programming Language :: Python :: 3.10",
        "Programming Language :: Python :: 3.11",
    ],
    keywords="wifi sdr openwifi remote-id drone monitoring injection",
    project_urls={
        "Bug Reports": "https://github.com/open-sdr/openwifi-hw/issues",
        "Source": "https://github.com/open-sdr/openwifi-hw",
    },
)
