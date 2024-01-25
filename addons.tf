# GP3 Encrypted Storage Class

resource "kubernetes_annotations" "gp2_default" {
  annotations = {
    "storageclass.kubernetes.io/is-default-class" : "false"
  }
  api_version = "storage.k8s.io/v1"
  kind        = "StorageClass"
  metadata {
    name = "gp2"
  }
  force = true

  depends_on = [module.eks]
}

resource "kubernetes_storage_class" "ebs_csi_encrypted_gp3_storage_class" {
  metadata {
    name = "gp3"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" : "true"
    }
  }

  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = "Delete"
  allow_volume_expansion = true
  volume_binding_mode    = "WaitForFirstConsumer"
  parameters = {
    fsType    = "xfs"
    encrypted = true
    type      = "gp3"
  }

  depends_on = [kubernetes_annotations.gp2_default]
}

# IRSA for EBS CSI Driver

module "ebs_csi_driver_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.20"

  role_name_prefix = "${module.eks.cluster_name}-ebs-csi-driver-"

  attach_ebs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }

  tags = local.tags
}

# EKS Blueprints Addons

module "eks_blueprints_addons" {
  source  = "aws-ia/eks-blueprints-addons/aws"
  version = "1.9.2"

  cluster_name      = module.eks.cluster_name
  cluster_endpoint  = module.eks.cluster_endpoint
  cluster_version   = module.eks.cluster_version
  oidc_provider_arn = module.eks.oidc_provider_arn

  eks_addons = {
    aws-ebs-csi-driver = {
      service_account_role_arn = module.ebs_csi_driver_irsa.iam_role_arn
    }
    coredns = {
      preserve = true
    }
    vpc-cni = {
      preserve = true
    }
    kube-proxy = {
      preserve = true
    }
  }

  enable_karpenter                  = true
  karpenter_enable_spot_termination = true
  karpenter = {
    repository_username = data.aws_ecrpublic_authorization_token.token.user_name
    repository_password = data.aws_ecrpublic_authorization_token.token.password
  }

  enable_aws_load_balancer_controller = true

  enable_argo_workflows = true
  argo_workflows = {
    name       = "argo-workflows"
    namespace  = "argo-workflows"
    repository = "https://argoproj.github.io/argo-helm"
    values     = [templatefile("${path.module}/helm-values/argo-workflows-values.yaml", {})]
  }

  enable_argo_events = true
  argo_events = {
    name       = "argo-events"
    namespace  = "argo-events"
    repository = "https://argoproj.github.io/argo-helm"
    values     = [templatefile("${path.module}/helm-values/argo-events-values.yaml", {})]
  }
}

# Data on EKS Kubernetes Addons

module "eks_data_addons" {
  source  = "aws-ia/eks-data-addons/aws"
  version = "~> 1.0" # ensure to update this to the latest/desired version

  oidc_provider_arn = module.eks.oidc_provider_arn

  enable_spark_operator = true
  spark_operator_helm_config = {
    values = [templatefile("${path.module}/helm-values/spark-operator-values.yaml", {})]
  }

  enable_yunikorn = var.enable_yunikorn
  yunikorn_helm_config = {
    values = [templatefile("${path.module}/helm-values/yunikorn-values.yaml", {
      image_version = "1.2.0"
    })]
  }
}

# Karpenter Provisioners

data "kubectl_path_documents" "karpenter_provisioners" {
  pattern = "${path.module}/karpenter-provisioners/spark-*.yaml"
  vars = {
    azs            = local.region
    eks_cluster_id = module.eks.cluster_name
  }
}

resource "kubectl_manifest" "karpenter_provisioner" {
  for_each  = toset(data.kubectl_path_documents.karpenter_provisioners.documents)
  yaml_body = each.value

  depends_on = [module.eks_blueprints_addons]
}

# S3 Bucket

module "s3_bucket" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "~> 3.0"

  bucket_prefix = "${local.name}-"

  # For example only - please evaluate for your environment
  force_destroy = true

  server_side_encryption_configuration = {
    rule = {
      apply_server_side_encryption_by_default = {
        sse_algorithm = "AES256"
      }
    }
  }

  tags = local.tags
}

resource "aws_s3_object" "this" {
  bucket       = module.s3_bucket.s3_bucket_id
  key          = "spark-event-logs/"
  content_type = "application/x-directory"
}

resource "aws_s3_object" "output" {
  bucket       = module.s3_bucket.s3_bucket_id
  key          = "taxi-trip/output/"
  content_type = "application/x-directory"
}

resource "aws_s3_object" "athena-queries" {
  bucket       = module.s3_bucket.s3_bucket_id
  key          = "athena-queries/"
  content_type = "application/x-directory"
}

# Glue Database, Table & Crawler

module "iam_assumable_role_glue" {
  count = var.enable_glue ? 1 : 0

  source = "terraform-aws-modules/iam/aws//modules/iam-assumable-role"

  trusted_role_services = [
    "glue.amazonaws.com"
  ]
  create_role       = true
  role_name         = format("%s-%s", local.name, "glue")
  role_requires_mfa = false

  custom_role_policy_arns = [
    "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole",
    "arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess",
  ]
}

resource "aws_glue_catalog_database" "this" {
  name = format("%s-%s", local.name, "taxi-trip")
}

resource "aws_glue_crawler" "this" {
  database_name = aws_glue_catalog_database.this.name
  name          = format("%s-%s", local.name, "taxi-trip")
  role          = module.iam_assumable_role_glue[0].iam_role_arn

  s3_target {
    path = "s3://${module.s3_bucket.s3_bucket_id}/${aws_s3_object.output.key}"
  }
}

resource "aws_glue_catalog_table" "this" {
  name          = format("%s-%s", local.name, "taxi-trip")
  database_name = aws_glue_catalog_database.this.name

  table_type = "EXTERNAL_TABLE"

  parameters = {
    EXTERNAL              = "TRUE"
    "parquet.compression" = "SNAPPY"
  }

  storage_descriptor {
    location      = "s3://${module.s3_bucket.s3_bucket_id}/${aws_s3_object.output.key}"
    input_format  = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat"

    ser_de_info {
      name                  = "taxi-trip"
      serialization_library = "org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe"

      parameters = {
        "serialization.format" = 1
      }
    }

    columns {
      name = "tpep_pickup_datetime"
      type = "timestamp"
    }

    columns {
      name = "tpep_dropoff_datetime"
      type = "timestamp"
    }

    columns {
      name = "trip_distance"
      type = "double"
    }

    columns {
      name = "fare_amount"
      type = "double"
    }

    columns {
      name = "tip_amount"
      type = "double"
    }

    columns {
      name = "tolls_amount"
      type = "double"
    }

    columns {
      name = "total_amount"
      type = "double"
    }

    columns {
      name = "current_date"
      type = "timestamp"
    }

  }
}
