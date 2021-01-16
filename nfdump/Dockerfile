FROM debian:10

RUN apt update \
    && apt install -y nfdump \
    && apt-get install -y nfdump-sflow \
    && apt install -y procps

WORKDIR /app
COPY entrypoint.sh .
RUN chmod a+x /app/entrypoint.sh

ENTRYPOINT [ "/bin/bash", "/app/entrypoint.sh" ]
