# --- SQS Queues ---
# We create three queues, each with its own DLQ (dead letter queue).
# A DLQ catches messages that fail processing repeatedly so they are
# not lost and can be inspected. This is the production pattern.
#
# visibility_timeout_seconds: how long a message is hidden from other
# consumers after one consumer picks it up. Must be >= your worker's
# processing timeout. We match what the application code expects:
#   biomass-ingestion: 30s
#   data-ingestion: 120s (CSV processing takes longer)
#   notifications: 30s
#
# message_retention_seconds: how long SQS keeps an unprocessed message.
# 1209600 = 14 days (the maximum). After this the message is gone.
#
# receive_wait_time_seconds: long polling. Workers wait up to 20 seconds
# for a message before returning empty. Reduces API calls and cost.
# Matches WaitTimeSeconds=20 in the application code.

locals {
  queues = {
    biomass = {
      visibility_timeout = 30
    }
    data-ingestion = {
      visibility_timeout = 120
    }
    notifications = {
      visibility_timeout = 30
    }
  }
}

# --- Dead Letter Queues ---
# Created first because the main queues reference their ARNs.
# max_receive_count = 3: if a message fails processing 3 times it
# moves to the DLQ. We saw this pattern work in Step 5 poison pill testing.

resource "aws_sqs_queue" "dlq" {
  for_each = local.queues

  name                      = "${var.project}-${each.key}-dlq"
  message_retention_seconds = 1209600
  receive_wait_time_seconds = 20

  tags = {
    Name        = "${var.project}-${each.key}-dlq"
    Project     = var.project
    Environment = var.environment
    Service     = each.key
  }
}

# --- Main Queues ---
# Each queue references its DLQ via a redrive policy.

resource "aws_sqs_queue" "main" {
  for_each = local.queues

  name                       = "${var.project}-${each.key}-queue"
  visibility_timeout_seconds = each.value.visibility_timeout
  message_retention_seconds  = 1209600
  receive_wait_time_seconds  = 20

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq[each.key].arn
    maxReceiveCount     = 3
  })

  tags = {
    Name        = "${var.project}-${each.key}-queue"
    Project     = var.project
    Environment = var.environment
    Service     = each.key
  }
}