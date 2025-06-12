// File: main.go
package main

import (
	"context"
	"fmt"
	"log"
	"os"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/costexplorer"
	"github.com/aws/aws-sdk-go-v2/service/costexplorer/types"
)

type CostTracker struct {
	client *costexplorer.Client
}

func NewCostTracker() (*CostTracker, error) {
	cfg, err := config.LoadDefaultConfig(context.TODO())
	if err != nil {
		return nil, fmt.Errorf("unable to load SDK config: %v", err)
	}

	return &CostTracker{
		client: costexplorer.NewFromConfig(cfg),
	}, nil
}

// method reciever
// It declares that the function following it is a method belonging to the CostTracker type
func (ct *CostTracker) GetCostsByService(days int) error {
	// Calculate date range
	endDate := time.Now()
	startDate := endDate.AddDate(0, 0, -days)

	// Prepare the request
	input := &costexplorer.GetCostAndUsageInput{
		TimePeriod: &types.DateInterval{
			Start: aws.String(startDate.Format("2006-01-02")),
			End:   aws.String(endDate.Format("2006-01-02")),
		},
		Granularity: types.GranularityMonthly,
		Metrics: []string{
			"BlendedCost",
		},
		GroupBy: []types.GroupDefinition{
			{
				Type: types.GroupDefinitionTypeDimension,
				Key:  aws.String("SERVICE"),
			},
		},
	}

	// Make the API call
	result, err := ct.client.GetCostAndUsage(context.TODO(), input)
	if err != nil {
		return fmt.Errorf("failed to get cost data: %v", err)
	}

	// Display results
	fmt.Printf("AWS Costs for the last %d days:\n", days)
	fmt.Println("=====================================")

	for _, resultByTime := range result.ResultsByTime {
		fmt.Printf("Period: %s to %s\n", *resultByTime.TimePeriod.Start, *resultByTime.TimePeriod.End)

		for _, group := range resultByTime.Groups {
			serviceName := group.Keys[0]
			cost := group.Metrics["BlendedCost"].Amount
			unit := group.Metrics["BlendedCost"].Unit

			fmt.Printf("  %-30s: %s %s\n", serviceName, *cost, *unit)
		}
		fmt.Println()
	}

	return nil
}

func main() {
	// Create cost tracker
	tracker, err := NewCostTracker()
	if err != nil {
		log.Fatalf("Failed to create cost tracker: %v", err)
	}

	// Default to 30 days if no args provided
	days := 30
	if len(os.Args) > 1 {
		// TODO: Add proper command line argument parsing
		fmt.Println("Usage: ./cost-tracker")
		fmt.Println("Currently showing last 30 days by default")
	}

	// Get and display costs
	if err := tracker.GetCostsByService(days); err != nil {
		log.Fatalf("Error getting costs: %v", err)
	}
}
