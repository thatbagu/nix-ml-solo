{
  "TrainingJobName": "${project}-${environment}-TIMESTAMP",
  "AlgorithmSpecification": {
    "TrainingImage": "${training_image_uri}",
    "TrainingInputMode": "File"
  },
  "RoleArn": "${execution_role_arn}",
  "InputDataConfig": [
    {
      "ChannelName": "train",
      "DataSource": {
        "S3DataSource": {
          "S3DataType": "S3Prefix",
          "S3Uri": "s3://${dvc_bucket_name}/data/train/",
          "S3DataDistributionType": "FullyReplicated"
        }
      }
    }
  ],
  "OutputDataConfig": {
    "S3OutputPath": "s3://${dvc_bucket_name}/training-output/"
  },
  "ResourceConfig": {
    "InstanceType": "ml.m5.xlarge",
    "InstanceCount": 1,
    "VolumeSizeInGB": 30
  },
  "StoppingCondition": {
    "MaxRuntimeInSeconds": 86400
  },
  "Environment": {
    "NIX_CACHE_BUCKET": "${nix_cache_bucket}",
    "AWS_DEFAULT_REGION": "${aws_region}",
    "MLFLOW_TRACKING_URI": "REPLACE_WITH_EC2_IP"
  },
  "Tags": [
    { "Key": "Project",     "Value": "${project}" },
    { "Key": "Environment", "Value": "${environment}" },
    { "Key": "ManagedBy",   "Value": "terraform" }
  ]
}
