# #!/bin/bash
# # This script runs inside the LocalStack container after it starts.
# # It creates the SQS queues and S3 bucket that the services expect.
# # awslocal is a wrapper around the AWS CLI that points at LocalStack
# # instead of real AWS.

# echo "Initialising LocalStack resources..."

# # Create the three SQS queues
# awslocal sqs create-queue \
#     --queue-name biomass-queue \
#     --region eu-west-1

# awslocal sqs create-queue \
#     --queue-name data-ingestion-queue \
#     --region eu-west-1

# awslocal sqs create-queue \
#     --queue-name notifications-queue \
#     --region eu-west-1

# # Create the S3 bucket for CSV uploads
# awslocal s3 mb s3://bebeque-uploads \
#     --region eu-west-1

# echo "LocalStack resources created successfully"

# # Print the queue URLs so you can see them in the logs
# echo "Queue URLs:"
# awslocal sqs get-queue-url --queue-name biomass-queue --region eu-west-1
# awslocal sqs get-queue-url --queue-name data-ingestion-queue --region eu-west-1
# awslocal sqs get-queue-url --queue-name notifications-queue --region eu-west-1

!/bin/bash

echo "Initialising LocalStack resources..."

awslocal sqs create-queue \
    --queue-name biomass-queue \
    --region us-east-1

awslocal sqs create-queue \
    --queue-name data-ingestion-queue \
    --region us-east-1

awslocal sqs create-queue \
    --queue-name notifications-queue \
    --region us-east-1

awslocal s3 mb s3://bebeque-uploads \
    --region us-east-1

echo "LocalStack resources created:"
awslocal sqs list-queues --region us-east-1


awslocal sqs create-queue --queue-name biomass-queue --region us-east-1
awslocal sqs create-queue --queue-name data-ingestion-queue --region us-east-1
awslocal sqs create-queue --queue-name notifications-queue --region us-east-1
awslocal s3 mb s3://bebeque-uploads --region us-east-1

echo "Verifying queues created:"
awslocal sqs list-queues --region us-east-1
echo "Init complete."