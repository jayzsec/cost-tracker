# Stage 1: The Builder Stage
# We use a specific Go version for reproducibility.
# Using 'alpine' as the base makes this stage's image smaller.
FROM golang:1.22-alpine AS builder

# Set the working directory inside the container. This is where our code will live.
WORKDIR /app

# Copy the go.mod and go.sum files first.
# This step is cached by Docker. If these files don't change, Docker will
# use the cached layer for the next step, speeding up subsequent builds.
COPY go.mod go.sum ./

# Download the Go application dependencies.
RUN go mod download

# Copy the rest of the application's source code into the container.
COPY . .

# Build the Go application.
# CGO_ENABLED=0 disables Cgo, which is necessary for creating a static binary.
# -ldflags "-s -w" strips debugging information, making the binary smaller.
# -o /cost-tracker specifies the output file name and location.
RUN CGO_ENABLED=0 GOOS=linux go build -v -a -ldflags "-s -w" -o /cost-tracker .

# ---

# Stage 2: The Final Stage
# We start from a minimal base image. 'scratch' is the most minimal image
# possible, containing nothing but our application. This is great for security
# and size. For applications needing CA certificates (for HTTPS requests),
# 'gcr.io/distroless/static-debian11' or 'alpine' are better choices.
# Let's use Alpine as it's very small but still gives us a shell for debugging if needed.
FROM alpine:latest

# It's a good practice to run containers as a non-root user.
# Let's create a user and group for our application.
RUN addgroup -S appgroup && adduser -S appuser -G appgroup

# Copy the compiled application binary from the 'builder' stage.
COPY --from=builder /cost-tracker /cost-tracker

# Copy any other necessary files, like configuration files.
# Assuming your app might need a config.json in the future.
# COPY config.json /config.json

# Switch to our non-root user.
USER appuser

# Expose the port that the application listens on.
# Update this if your application uses a different port.
EXPOSE 8080

# The command to run when the container starts.
# This executes our application binary.
ENTRYPOINT ["/cost-tracker"]
