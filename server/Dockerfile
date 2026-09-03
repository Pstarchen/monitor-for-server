FROM maven:3.9.9-eclipse-temurin-21 AS build
WORKDIR /workspace
COPY pom.xml .
COPY maven-settings.xml /root/.m2/settings.xml
RUN mvn -B -q -DskipTests dependency:go-offline
COPY src src
RUN mvn -B -q -DskipTests package

FROM eclipse-temurin:21-jre-alpine
ARG VERSION=dev
LABEL org.opencontainers.image.version=$VERSION
RUN addgroup -S monitor && adduser -S -G monitor monitor
WORKDIR /app
COPY --from=build /workspace/target/monitor-server-1.0.0.jar app.jar
USER monitor
EXPOSE 8080
ENTRYPOINT ["java", "-XX:MaxRAMPercentage=75", "-jar", "/app/app.jar"]
