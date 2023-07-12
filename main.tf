provider "aws" {
  region = local.region
}

data "aws_availability_zones" "available" {}

locals {
  name   = "msk-mysql-debezium"
  region = "us-east-1"

  vpc_cidr = "10.0.0.0/16"
  azs      = slice(data.aws_availability_zones.available.names, 0, 3)

  connector_external_url = "https://repo1.maven.org/maven2/io/debezium/debezium-connector-mysql/2.3.0.Final/debezium-connector-mysql-2.3.0.Final-plugin.tar.gz"
  connector              = "debezium-connector-mysql/debezium-connector-mysql-2.3.0.Final.jar"

  tags = {
    Example    = local.name
    GithubRepo = "terraform-aws-msk-kafka-cluster"
    GithubOrg  = "terraform-aws-modules"
  }
}

################################################################################
# RDS Database
################################################################################

module "db" {
  source = "terraform-aws-modules/rds/aws"

  identifier = local.name

  # All available versions: http://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/CHAP_MySQL.html#MySQL.Concepts.VersionMgmt
  engine               = "mysql"
  engine_version       = "8.0"
  family               = "mysql8.0" # DB parameter group
  major_engine_version = "8.0"      # DB option group
  instance_class       = "db.t4g.micro"

  allocated_storage = 20

  db_name  = "completeMysql"
  username = "complete_mysql"
  port     = 3306

  db_subnet_group_name   = module.vpc.database_subnet_group
  vpc_security_group_ids = [module.security_group_database.security_group_id]

  maintenance_window = "Mon:00:00-Mon:03:00"
  backup_window      = "03:00-06:00"

  backup_retention_period = 0

  tags = local.tags
}

################################################################################
# MSK Cluster
################################################################################

module "msk_cluster" {
  source = "terraform-aws-modules/msk-kafka-cluster/aws"

  name                   = local.name
  kafka_version          = "3.4.0"
  number_of_broker_nodes = 3

  broker_node_client_subnets  = module.vpc.private_subnets
  broker_node_instance_type   = "kafka.t3.small"
  broker_node_security_groups = [module.security_group.security_group_id]

  # Connect custom plugin(s)
  connect_custom_plugins = {
    debezium = {
      name         = "debezium-mysql"
      description  = "Debezium MySQL connector"
      content_type = "JAR"

      s3_bucket_arn     = module.s3_bucket.s3_bucket_arn
      s3_file_key       = aws_s3_object.debezium_connector.id
      s3_object_version = aws_s3_object.debezium_connector.version_id

      timeouts = {
        create = "20m"
      }
    }
  }

  # Connect worker configuration
  create_connect_worker_configuration           = true
  connect_worker_config_name                    = local.name
  connect_worker_config_description             = "Example connect worker configuration"
  connect_worker_config_properties_file_content = <<-EOT
    key.converter=org.apache.kafka.connect.storage.StringConverter
    value.converter=org.apache.kafka.connect.storage.StringConverter
  EOT
  
  schema_registries = {
    debezium = {
      name        = "debezium"
      description = "Schema registry for Debezium"
    }
  }

  tags = local.tags
}



################################################################################
# Connector
################################################################################

resource "aws_mskconnect_connector" "debezium_mysql" {
  name = local.name

  kafkaconnect_version = "2.7.1"

  capacity {
    autoscaling {
      mcu_count        = 1
      min_worker_count = 1
      max_worker_count = 2

      scale_in_policy {
        cpu_utilization_percentage = 20
      }

      scale_out_policy {
        cpu_utilization_percentage = 80
      }
    }
  }

  connector_configuration = {
    "name": "database_connector",
    "topic.prefix": "sample",
    "connector.class": "io.debezium.connector.mysql.MySqlConnector",
    "database.server.id": "1",
    "tasks.max": "1",
    "database.history.kafka.bootstrap.servers": "[KAFKA_BROKERS]",
    "database.history.kafka.topic": "database_connector.mysql",
    "database.server.name": "mysql",
    "database.hostname": "[DATABASE_HOST]",
    "database.port": "3306",
    "database.user": "[DATABASE_USERNAME]",
    "database.password": "[DATABASE_PASSWORD]",
    "database.whitelist": "[DATABASE_SCHEMA]",
    "table.include.list": "[DATABASE_SCHEMA].users,[DATABASE_SCHEMA].products,[DATABASE_SCHEMA].purchases",
    "internal.key.converter.schemas.enable": "false",
    "transforms.unwrap.add.source.fields": "ts_ms",
    "key.converter.schemas.enable": "false",
    "internal.key.converter": "org.apache.kafka.connect.json.JsonConverter",
    "internal.value.converter.schemas.enable": "false",
    "value.converter.schemas.enable": "false",
    "internal.value.converter": "org.apache.kafka.connect.json.JsonConverter",
    "transforms": "unwrap",
    "transforms.unwrap.type": "io.debezium.transforms.ExtractNewRecordState",
    "schema.history.internal.kafka.topic": "schemahistory.fullfillment",
    "schema.history.internal.kafka.bootstrap.servers": "[KAFKA_BROKERS]",
    "errors.log.enable": "true",
    "snapshot.mode": "when_needed",
    "key.converter": "io.apicurio.registry.utils.converter.AvroConverter",
    "key.converter.apicurio.registry.url": "http://localhost:8080/apis/registry/v2",
    "key.converter.apicurio.registry.auto-register": "true",
    "key.converter.apicurio.registry.find-latest": "true",
    "value.converter": "io.apicurio.registry.utils.converter.AvroConverter",
    "value.converter.apicurio.registry.url": "http://localhost:8080/apis/registry/v2",
    "value.converter.apicurio.registry.auto-register": "true",
    "value.converter.apicurio.registry.find-latest": "true",
    "value.converter.apicurio.registry.as-confluent": "true",
    "value.converter.apicurio.registry.use-id": "contentId",
    "schema.name.adjustment.mode": "avro"
  }

  kafka_cluster {
    apache_kafka_cluster {
      bootstrap_servers = module.msk_cluster

      vpc {
        security_groups = [module.security_group.security_group_id, module.security_group_database.security_group_id]
        subnets         = [module.vpc.private_subnet_group]
      }
    }
  }

  kafka_cluster_client_authentication {
    authentication_type = "NONE"
  }

  kafka_cluster_encryption_in_transit {
    encryption_type = "TLS"
  }

  plugin {
    custom_plugin {
      arn      = module.msk_cluster.aws_mskconnect_custom_plugin.arn
      revision = module.msk_cluster.aws_mskconnect_custom_plugin.latest_revision
    }
  }

  service_execution_role_arn = aws_iam_role.example.arn
}

################################################################################
# Supporting Resources
################################################################################

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = local.name
  cidr = local.vpc_cidr

  azs              = local.azs
  public_subnets   = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k)]
  private_subnets  = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 3)]
  database_subnets = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 6)]

  create_database_subnet_group = true
  enable_nat_gateway           = true
  single_nat_gateway           = true

  tags = local.tags
}

module "security_group" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 5.0"

  name        = local.name
  description = "Security group for ${local.name}"
  vpc_id      = module.vpc.vpc_id

  ingress_cidr_blocks = module.vpc.private_subnets_cidr_blocks
  ingress_rules = [
    "kafka-broker-tcp",
    "kafka-broker-tls-tcp"
  ]

  tags = local.tags
}


module "security_group_database" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 5.0"

  name        = local.name
  description = "Complete MySQL example security group"
  vpc_id      = module.vpc.vpc_id

  # ingress
  ingress_with_cidr_blocks = [
    {
      from_port   = 3306
      to_port     = 3306
      protocol    = "tcp"
      description = "MySQL access from within VPC"
      cidr_blocks = module.vpc.vpc_cidr_block
    },
  ]

  tags = local.tags
}

module "s3_bucket" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "~> 3.0"

  bucket_prefix = local.name
  acl           = "private"
  
  control_object_ownership = true
  object_ownership         = "ObjectWriter"

  versioning = {
    enabled = true
  }

  # Allow deletion of non-empty bucket for testing
  force_destroy = true

  attach_deny_insecure_transport_policy = true
  server_side_encryption_configuration = {
    rule = {
      apply_server_side_encryption_by_default = {
        sse_algorithm = "AES256"
      }
    }
  }

  tags = local.tags
}

resource "aws_s3_object" "debezium_connector" {
  bucket = module.s3_bucket.s3_bucket_id
  key    = local.connector
  source = local.connector

  depends_on = [
    null_resource.debezium_connector
  ]
}

resource "null_resource" "debezium_connector" {
  provisioner "local-exec" {
    command = <<-EOT
      wget -c ${local.connector_external_url} -O connector.tar.gz \
        && tar -zxvf connector.tar.gz  ${local.connector} \
        && rm *.tar.gz
    EOT
  }
}
