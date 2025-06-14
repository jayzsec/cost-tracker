// File: main_test.go
package main

import (
	"context"
	"fmt"
	"testing"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/costexplorer"
	"github.com/aws/aws-sdk-go-v2/service/costexplorer/types"
	"go.uber.org/zap/zaptest"
)

// mockCostExplorerClient is a mock implementation of the CostExplorerAPI interface.
type mockCostExplorerClient struct {
	GetCostAndUsageFunc func(ctx context.Context, params *costexplorer.GetCostAndUsageInput, optFns ...func(*costexplorer.Options)) (*costexplorer.GetCostAndUsageOutput, error)
}

// GetCostAndUsage satisfies the CostExplorerAPI interface.
func (m *mockCostExplorerClient) GetCostAndUsage(ctx context.Context, params *costexplorer.GetCostAndUsageInput, optFns ...func(*costexplorer.Options)) (*costexplorer.GetCostAndUsageOutput, error) {
	if m.GetCostAndUsageFunc != nil {
		return m.GetCostAndUsageFunc(ctx, params, optFns...)
	}
	return nil, fmt.Errorf("GetCostAndUsageFunc not implemented in mock")
}

func TestNewCostTracker(t *testing.T) {
	ctx := context.Background()
	// This test relies on the AWS SDK's default config loading behavior.
	// In an environment where AWS config is not available/valid, it might return an error.
	tracker, err := NewCostTracker(ctx)

	if err == nil { // Successfully loaded config
		if tracker == nil {
			t.Errorf("NewCostTracker() returned nil tracker with no error")
		}
		if tracker != nil && tracker.client == nil {
			t.Errorf("NewCostTracker() tracker.client is nil")
		}
	} else { // Failed to load config
		if tracker != nil {
			t.Errorf("NewCostTracker() returned non-nil tracker with error: %v", err)
		}
		// This is an expected outcome if AWS config isn't set up, so log for info.
		t.Logf("NewCostTracker() returned expected error due to config loading: %v", err)
	}
}

func TestGetCostsByService(t *testing.T) {
	// Initialize logger for tests. This logger will fail the test on Error/Fatal logs.
	testLogger := zaptest.NewLogger(t)
	logger = testLogger.Sugar() // Override the global logger for testing purposes

	ctx := context.Background()

	// Define fixed dates for predictable test results
	fixedNow := time.Date(2024, 1, 31, 0, 0, 0, 0, time.UTC)
	defaultStartDate := fixedNow.AddDate(0, 0, -30).Format(AWSDateFormat)
	defaultEndDate := fixedNow.Format(AWSDateFormat)

	testCases := []struct {
		name              string
		days              int
		mockSetup         func() *mockCostExplorerClient
		expectedCostsLen  int
		expectedError     bool
		checkSpecificCost func(t *testing.T, costs []CostByTime)
	}{
		{
			name: "successful retrieval",
			days: 30,
			mockSetup: func() *mockCostExplorerClient {
				return &mockCostExplorerClient{
					GetCostAndUsageFunc: func(ctx context.Context, params *costexplorer.GetCostAndUsageInput, optFns ...func(*costexplorer.Options)) (*costexplorer.GetCostAndUsageOutput, error) {
						return &costexplorer.GetCostAndUsageOutput{
							ResultsByTime: []types.ResultByTime{
								{
									TimePeriod: &types.DateInterval{Start: aws.String(defaultStartDate), End: aws.String(defaultEndDate)},
									Groups: []types.Group{
										{
											Keys: []string{"Amazon EC2"},
											Metrics: map[string]types.MetricValue{
												MetricBlendedCost: {Amount: aws.String("100.00"), Unit: aws.String("USD")},
											},
										},
									},
								},
							},
						}, nil
					},
				}
			},
			expectedCostsLen: 1,
			expectedError:    false,
			checkSpecificCost: func(t *testing.T, costs []CostByTime) {
				if len(costs[0].ServiceCosts) != 1 {
					t.Fatalf("expected 1 service cost, got %d", len(costs[0].ServiceCosts))
				}
				if costs[0].ServiceCosts[0].ServiceName != "Amazon EC2" {
					t.Errorf("expected service name 'Amazon EC2', got '%s'", costs[0].ServiceCosts[0].ServiceName)
				}
				if costs[0].ServiceCosts[0].Amount != "100.00" {
					t.Errorf("expected amount '100.00', got '%s'", costs[0].ServiceCosts[0].Amount)
				}
			},
		},
		{
			name: "API error",
			days: 30,
			mockSetup: func() *mockCostExplorerClient {
				return &mockCostExplorerClient{
					GetCostAndUsageFunc: func(ctx context.Context, params *costexplorer.GetCostAndUsageInput, optFns ...func(*costexplorer.Options)) (*costexplorer.GetCostAndUsageOutput, error) {
						return nil, fmt.Errorf("simulated AWS API error")
					},
				}
			},
			expectedCostsLen: 0,
			expectedError:    true,
		},
		{
			name: "invalid days (zero)",
			days: 0,
			mockSetup: func() *mockCostExplorerClient { // Mock won't be called due to early return
				return &mockCostExplorerClient{}
			},
			expectedCostsLen: 0,
			expectedError:    true,
		},
		{
			name: "invalid days (negative)",
			days: -5,
			mockSetup: func() *mockCostExplorerClient { // Mock won't be called
				return &mockCostExplorerClient{}
			},
			expectedCostsLen: 0,
			expectedError:    true,
		},
		{
			name: "no results by time from API",
			days: 30,
			mockSetup: func() *mockCostExplorerClient {
				return &mockCostExplorerClient{
					GetCostAndUsageFunc: func(ctx context.Context, params *costexplorer.GetCostAndUsageInput, optFns ...func(*costexplorer.Options)) (*costexplorer.GetCostAndUsageOutput, error) {
						return &costexplorer.GetCostAndUsageOutput{
							ResultsByTime: []types.ResultByTime{}, // Empty results
						}, nil
					},
				}
			},
			expectedCostsLen: 0,
			expectedError:    false,
		},
		{
			name: "metric not found for a service",
			days: 30,
			mockSetup: func() *mockCostExplorerClient {
				return &mockCostExplorerClient{
					GetCostAndUsageFunc: func(ctx context.Context, params *costexplorer.GetCostAndUsageInput, optFns ...func(*costexplorer.Options)) (*costexplorer.GetCostAndUsageOutput, error) {
						return &costexplorer.GetCostAndUsageOutput{
							ResultsByTime: []types.ResultByTime{
								{
									TimePeriod: &types.DateInterval{Start: aws.String(defaultStartDate), End: aws.String(defaultEndDate)},
									Groups: []types.Group{
										{
											Keys:    []string{"Amazon S3"},
											Metrics: map[string]types.MetricValue{
												// MetricBlendedCost is missing
											},
										},
									},
								},
							},
						}, nil
					},
				}
			},
			expectedCostsLen: 1, // One period, but ServiceCosts within it should be empty
			expectedError:    false,
			checkSpecificCost: func(t *testing.T, costs []CostByTime) {
				if len(costs[0].ServiceCosts) != 0 {
					t.Errorf("expected 0 service costs due to missing metric, got %d", len(costs[0].ServiceCosts))
				}
			},
		},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			mockClient := tc.mockSetup()
			tracker := &CostTracker{client: mockClient} // Inject mock client

			costs, err := tracker.GetCostsByService(ctx, tc.days)

			if tc.expectedError {
				if err == nil {
					t.Errorf("expected an error, but got nil")
				}
			} else {
				if err != nil {
					t.Errorf("did not expect an error, but got: %v", err)
				}
			}

			if len(costs) != tc.expectedCostsLen {
				t.Errorf("expected %d cost entries, got %d", tc.expectedCostsLen, len(costs))
			}

			if tc.checkSpecificCost != nil && err == nil && len(costs) > 0 { // Ensure costs is not empty before checking
				tc.checkSpecificCost(t, costs)
			}
		})
	}
}
