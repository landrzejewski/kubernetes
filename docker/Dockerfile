FROM eclipse-temurin:21-jre-alpine

ARG USERNAME=user
RUN adduser --gecos "$USERNAME" --disabled-password --shell /bin/sh --uid 1014 ${USERNAME} \
    && addgroup ${USERNAME} ${USERNAME}

USER ${USERNAME}

COPY target/configuration-server.jar /home/$USERNAME

WORKDIR /home/$USERNAME

ENTRYPOINT ["java", "-jar", "-Dspring.cloud.config.server.git.uri=${GIT_URI}", "-Dspring.cloud.config.server.git.search-paths=${SEARCH_PATHS}", "-Dspring.cloud.stream.kafka.binder.brokers=${KAFKA_BROKERS}", "configuration-server.jar"]