FROM ghcr.io/berriai/litellm:main-latest

COPY generate-config.py /usr/local/bin/generate-config.py
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /usr/local/bin/generate-config.py /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
