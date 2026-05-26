FROM ubuntu:24.04

# Avoid interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Install prerequisites and configure the official NodeSource repository (Node 20 LTS)
RUN apt-get update && apt-get install -y --no-install-recommends \
  ca-certificates \
  curl \
  gnupg \
  && curl -fsSL https://deb.nodesource.com/setup_20.x | bash -

# Install Node.js along with build tools and dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
  bc \
  ccache \
  glslc \
  libssl-dev \
  libvulkan-dev \
  vulkan-tools \
  libcurl4-openssl-dev \
  ninja-build \
  spirv-headers \
  build-essential \
  cmake \
  git \
  git-lfs \
  wget \
  pkg-config \
  python3 \
  python3-dev \
  python3-venv \
  python3-pip \
  shellcheck \
  tcl \
  unzip \
  time \
  vim \
  nodejs \
  && rm -rf /var/lib/apt/lists/*

# Register CUDA library path for the linker (Jetson/SBSA architecture)
RUN echo "/usr/local/cuda/targets/sbsa-linux/lib" > /etc/ld.so.conf.d/cuda.conf && ldconfig

# Create low-privilege user
RUN useradd -m -s /bin/bash ggml

# Define a shared, permanent browser cache directory accessible to everyone
ENV PLAYWRIGHT_BROWSERS_PATH=/ms-playwright
RUN mkdir -p /ms-playwright && chown -R ggml:ggml /ms-playwright

# NOTE: this is synchronized with the version used by llama.cpp's webui!
RUN ELECTRON_SKIP_BINARY_DOWNLOAD=1 npx playwright@1.56.1 install --with-deps

# Copy and set up the entrypoint script
COPY start.sh /start.sh
RUN chmod +x /start.sh && chown ggml:ggml /start.sh

USER ggml
WORKDIR /home/ggml

# Initialize git-lfs for the ggml user
RUN git lfs install

ENTRYPOINT ["/start.sh"]

