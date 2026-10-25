# The official image plus pgBackRest, which postgres calls as its archive_command.
# Built on t4a by `docker compose build`; bump both versions together.
FROM postgres:18.6-alpine
RUN apk add --no-cache pgbackrest=2.58.0-r0
