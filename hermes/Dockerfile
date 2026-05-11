FROM nousresearch/hermes-agent:v2026.4.23
USER root
RUN apt-get update && apt-get install -y sudo curl unzip && rm -rf /var/lib/apt/lists/* \
    && echo "hermes ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/hermes \
    && chmod 0440 /etc/sudoers.d/hermes
ARG TARGETARCH
RUN curl -sLO "https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/linux/${TARGETARCH}/kubectl" \
    && chmod +x kubectl && mv kubectl /usr/local/bin/
RUN AWSARCH=$([ "$TARGETARCH" = "amd64" ] && echo "x86_64" || echo "aarch64") \
    && curl -s "https://awscli.amazonaws.com/awscli-exe-linux-${AWSARCH}.zip" -o /tmp/awscliv2.zip \
    && cd /tmp && unzip -qo awscliv2.zip && ./aws/install && rm -rf /tmp/aws /tmp/awscliv2.zip
USER hermes
