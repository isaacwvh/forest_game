FROM golang:1.26 AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -o /out/forest ./cmd/forest

FROM scratch
ARG FOREST_RELEASE_COMMIT=unknown
LABEL org.opencontainers.image.revision=$FOREST_RELEASE_COMMIT
COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=build /out/forest /forest
USER 10001:10001
EXPOSE 8000
ENTRYPOINT ["/forest"]
CMD ["serve"]
