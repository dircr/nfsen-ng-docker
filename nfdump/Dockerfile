FROM debian:10

RUN apt update && apt install -y nfdump

WORKDIR /app
COPY entrypoint.sh .
RUN chmod a+x /app/entrypoint.sh

ENTRYPOINT [ "/app/entrypoint.sh" ]