using Confluent.Kafka;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;

namespace EventLogs.WorkflowProcessor;

public static class TestConsumer
{
    public static void TestReadOneMessage(ILogger logger)
    {
        var configuration = new ConfigurationBuilder()
            .SetBasePath(Directory.GetCurrentDirectory())
            .AddJsonFile("appsettings.json", optional: false)
            .AddEnvironmentVariables()
            .Build();

        var region = configuration.GetValue<string>("Region") ?? "us-east";
        var kafkaBootstrap = configuration.GetValue<string>("KafkaBootstrap") ?? "kafka:9093";
        var topic = $"request-events.{region}";
        var partition = 0;

        logger.LogInformation("=== Test Consumer ===");
        logger.LogInformation("Kafka: {Bootstrap}, Topic: {Topic}, Partition: {Partition}",
            kafkaBootstrap, topic, partition);

        var config = new ConsumerConfig
        {
            BootstrapServers = kafkaBootstrap,
            GroupId = $"test-consumer-{DateTime.UtcNow.Ticks}",
            AutoOffsetReset = AutoOffsetReset.Earliest,
            EnableAutoCommit = false,
            EnableAutoOffsetStore = false
        };

        using var consumer = new ConsumerBuilder<string, string>(config).Build();

        logger.LogInformation("Consumer created, waiting 1 second...");
        Thread.Sleep(1000);

        consumer.Assign(new TopicPartition(topic, partition));
        logger.LogInformation("Assigned to partition {Partition}", partition);

        // Get watermark offsets
        var watermarks = consumer.QueryWatermarkOffsets(new TopicPartition(topic, partition), TimeSpan.FromSeconds(5));
        logger.LogInformation("Watermark offsets - Low: {Low}, High: {High}", watermarks.Low, watermarks.High);

        if (watermarks.High > watermarks.Low)
        {
            logger.LogInformation("Messages available: {Count}", watermarks.High - watermarks.Low);

            // Try to consume one message
            logger.LogInformation("Attempting to consume one message (10 second timeout)...");
            var result = consumer.Consume(TimeSpan.FromSeconds(10));

            if (result != null)
            {
                logger.LogInformation("SUCCESS! Consumed message:");
                logger.LogInformation("  Offset: {Offset}", result.Offset);
                logger.LogInformation("  Partition: {Partition}", result.Partition);
                logger.LogInformation("  Key: {Key}", result.Message.Key ?? "(null)");

                if (result.Message.Value != null)
                {
                    logger.LogInformation("  Value length: {Length} bytes", result.Message.Value.Length);
                    logger.LogInformation("  Value (first 200 chars): {Value}",
                        result.Message.Value.Substring(0, Math.Min(200, result.Message.Value.Length)));
                }
                else
                {
                    logger.LogInformation("  Value: (null)");
                }
            }
            else
            {
                logger.LogError("FAILED! Consume returned null despite messages being available");
            }
        }
        else
        {
            logger.LogWarning("No messages available in topic");
        }

        consumer.Close();
        logger.LogInformation("Test complete");
    }
}
