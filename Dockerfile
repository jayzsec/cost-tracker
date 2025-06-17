# Stage 1: The build environment
# We use the official Golang image, which contains all the necessary tools to build our app.
# Using '-alpine' keeps the build environment itself smaller.
FROM golang:1.21-alpine AS builder

# Set the working directory inside the container.
WORKDIR /app

# Copy the Go module files and download dependencies.
# This is done in a separate layer to leverage Docker's build cache.
# Dependencies will only be re-downloaded if go.mod or go.sum change.
# Note: Before running, ensure `go mod init <your-module-name>` and `go mod tidy` have been run locally.
COPY go.mod go.sum ./
RUN go mod download

# Copy the rest of the application source code.
COPY . .

# Build the Go application.
# CGO_ENABLED=0 creates a statically-linked binary, which is needed to run in a minimal 'distroless' or 'alpine' image.
# -o /cost-tracker specifies the output file name and location.
RUN CGO_ENABLED=0 go build -ldflags="-w -s" -o /cost-tracker .

# Stage 2: The final production image
# We use a minimal alpine image which is very small and has a reduced attack surface.
FROM alpine:latest

# Copy the compiled binary from the 'builder' stage.
COPY --from=builder /cost-tracker /cost-tracker

# (Optional) Copy the configuration file.
# Note: In a production Kubernetes environment, you would typically manage this
# configuration via ConfigMaps and Secrets, not by including the file in the image.
COPY cost-tracker-config.json /cost-tracker-config.json

# Set the command to run when the container starts.
# This will execute the cost-tracker application.
ENTRYPOINT ["/cost-tracker", "get"]