# AWS Cost Tracker

A Go-based tool to track and analyze AWS costs.

## Setup

1. Ensure you have Go 1.21+ installed
2. Configure AWS credentials (via AWS CLI, environment variables, or IAM role)
3. Install dependencies:
   ```bash
   go mod tidy
   ```

## Required AWS Permissions

Your AWS user/role needs these permissions:
```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "ce:GetCostAndUsage",
                "ce:GetUsageAndCosts"
            ],
            "Resource": "*"
        }
    ]
}
```

## Usage

```bash
go build -o cost-tracker
./cost-tracker
```

## Next Steps

- [ ] Add command line argument parsing (cobra CLI)
- [ ] Add filtering by date range
- [ ] Add cost threshold alerts
- [ ] Export to JSON/CSV
- [ ] Add Slack notifications
- [ ] Containerize for Kubernetes deployment