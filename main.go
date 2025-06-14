// File: main.go
package main

import (
	"context"
	"fmt"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/costexplorer"
	"github.com/aws/aws-sdk-go-v2/service/costexplorer/types"
	"github.com/spf13/cobra"
	"go.uber.org/zap"
)

const (
	AWSDateFormat        = "2006-01-02"                       // AWS date format used in API requests
	MetricBlendedCost    = "BlendedCost"                      // Metric for blended cost
	GranularityMonthly   = types.GranularityMonthly           // Monthly granularity for cost data
	GroupByTypeDimension = types.GroupDefinitionTypeDimension // Group by dimension type
	GroupByServiceKey    = "SERVICE"                          // Key for grouping by service
	DefaultDays          = 30                                 // Default number of days to look back for cost data
)

var logger *zap.SugaredLogger

// CostTracker holds the AWS Cost Explorer client.
type CostTracker struct {
	client *costexplorer.Client
}

// NewCostTracker initializes a new CostTracker with the default AWS configuration.
// It returns an error if the AWS SDK configuration cannot be loaded.
func NewCostTracker(ctx context.Context) (*CostTracker, error) {
	cfg, err := config.LoadDefaultConfig(ctx)
	if err != nil {
		return nil, fmt.Errorf("unable to load SDK config: %w", err) // Use %w for error wrapping
	}

	return &CostTracker{
		client: costexplorer.NewFromConfig(cfg),
	}, nil
}

// ServiceCost represents the cost for a specific AWS service.
type ServiceCost struct {
	ServiceName string
	Amount      string
	Unit        string
}

type CostByTime struct {
	Start        string
	End          string
	ServiceCosts []ServiceCost
}

// GetCostsByService retrieves AWS costs grouped by service for a specified number of days.
// It takes a context for cancellation and timeouts, and an integer representing the number of days.
// It returns a slice of CostByTime and an error if the API call fails.
// Uses method reciever
// It declares that the function following it is a method belonging to the CostTracker type
func (ct *CostTracker) GetCostsByService(ctx context.Context, days int) ([]CostByTime, error) {
	if days <= 0 {
		return nil, fmt.Errorf("days must be a positive integer, got %d", days)
	}

	// Calculate date range
	endDate := time.Now()
	startDate := endDate.AddDate(0, 0, -days)

	// Prepare the request
	input := &costexplorer.GetCostAndUsageInput{
		TimePeriod: &types.DateInterval{
			Start: aws.String(startDate.Format(AWSDateFormat)),
			End:   aws.String(endDate.Format(AWSDateFormat)),
		},
		Granularity: GranularityMonthly,
		Metrics: []string{
			MetricBlendedCost, // Use the constant for blended cost metric
		},
		GroupBy: []types.GroupDefinition{
			{
				Type: GroupByTypeDimension,
				Key:  aws.String(GroupByServiceKey),
			},
		},
	}

	// Make the API call
	result, err := ct.client.GetCostAndUsage(ctx, input)
	if err != nil {
		return nil, fmt.Errorf("failed to get cost data from AWS Cost Explorer: %w", err)
	}

	var allCosts []CostByTime
	for _, resultByTime := range result.ResultsByTime {
		periodCosts := CostByTime{
			Start: *resultByTime.TimePeriod.Start,
			End:   *resultByTime.TimePeriod.End,
		}

		for _, group := range resultByTime.Groups {
			serviceName := "N/A"
			if len(group.Keys) > 0 {
				serviceName = group.Keys[0] // Use the first key as the service name
			}

			// Safely access the metrics
			metric, ok := group.Metrics[MetricBlendedCost]
			if !ok || metric.Amount == nil || metric.Unit == nil {
				logger.Warnw("Metric not found or incomplete for service",
					"metric", MetricBlendedCost,
					"service", serviceName,
					"periodStart", periodCosts.Start,
					"periodEnd", periodCosts.End)
				continue // Skip if metric is missing or incomplete
			}

			periodCosts.ServiceCosts = append(periodCosts.ServiceCosts, ServiceCost{
				ServiceName: serviceName,
				Amount:      *metric.Amount,
				Unit:        *metric.Unit,
			})
		}
		allCosts = append(allCosts, periodCosts)
	}

	return allCosts, nil
}

// displayCosts prints the retrieved cost data to the console.
func displayCosts(costs []CostByTime, days int) {
	fmt.Printf("AWS Costs for the last %d days:\n", days)
	fmt.Println("=====================================")
	if len(costs) == 0 {
		fmt.Println("No cost data found for the specified period.")
		return
	}
	for _, period := range costs {
		fmt.Printf("Period: %s to %s\n", period.Start, period.End)
		if len(period.ServiceCosts) == 0 {
			fmt.Println("  No service costs found for this period.")
		} else {
			for _, serviceCost := range period.ServiceCosts {
				// Consider adding financial formatting (e.g., using "github.com/shopspring/decimal")
				fmt.Printf("  %-30s: %s %s\n", serviceCost.ServiceName, serviceCost.Amount, serviceCost.Unit)
			}
		}
		fmt.Println()
	}
}

var rootCmd = &cobra.Command{
	Use:   "cost-tracker",
	Short: "A CLI tool to track AWS costs.",
	Long:  `cost-tracker is a CLI tool that fetches and displays AWS cost and usage data grouped by service.`,
}

var getCostsCmd = &cobra.Command{
	Use:   "get",
	Short: "Get AWS costs for a specified number of days.",
	Long:  `Retrieves and displays AWS costs from Cost Explorer for the last N days, grouped by service.`,
	Run: func(cmd *cobra.Command, args []string) {
		days, err := cmd.Flags().GetInt("days")
		if err != nil {
			logger.Fatalw("Error getting 'days' flag", "error", err)
		}

		// Use a background context for the main application lifecycle
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute) // Example: 5-minute timeout
		defer cancel()                                                          // Ensure the context is cancelled when main exits

		// Create cost tracker
		tracker, err := NewCostTracker(ctx)
		if err != nil {
			logger.Fatalw("Failed to create cost tracker", "error", err)
		}

		// Get costs
		costs, err := tracker.GetCostsByService(ctx, days)
		if err != nil {
			logger.Fatalw("Error getting costs", "error", err)
		}
		// Display costs
		displayCosts(costs, days)
	},
}

func init() {
	// Initialize zap logger
	rawLogger, err := zap.NewProduction() // Or zap.NewDevelopment() for more verbose, human-readable logs
	if err != nil {
		// Fallback to standard log if zap initialization fails
		fmt.Printf("failed to initialize zap logger: %v\n", err) // Use fmt here as logger isn't initialized
		panic(err)                                               // or os.Exit(1)
	}
	logger = rawLogger.Sugar()

	rootCmd.AddCommand(getCostsCmd)
	getCostsCmd.Flags().IntP("days", "d", DefaultDays, "Number of days to look back for cost data")
}

func main() {
	defer logger.Sync() // Flushes any buffered log entries
	if err := rootCmd.Execute(); err != nil {
		logger.Fatalw("Error executing root command", "error", err)
	}
}
