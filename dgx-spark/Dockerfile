FROM ubuntu:24.04

# Avoid interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Install build tools and dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
  bc \
  ca-certificates \
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
  curl \
  pkg-config \
  python3 \
  python3-venv \
  python3-pip \
  unzip \
  time \
  && rm -rf /var/lib/apt/lists/*

# Register CUDA library path for the linker (Jetson uses non-standard path)
RUN echo "/usr/local/cuda/targets/sbsa-linux/lib" > /etc/ld.so.conf.d/cuda.conf && ldconfig

# Create low-privilege user
RUN useradd -m -s /bin/bash ggml

# Copy and set up the entrypoint script
COPY start.sh /start.sh
RUN chmod +x /start.sh && chown ggml:ggml /start.sh

USER ggml
WORKDIR /home/ggml

# Initialize git-lfs for the ggml user
RUN git lfs install

ENTRYPOINT ["/start.sh"]
