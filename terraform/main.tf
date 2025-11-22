terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.0"
    }
  }
}

# --- Variables ---
variable "project_id" {
  description = "The GCP Project ID"
  type        = string
}

variable "region" {
  description = "The GCP region"
  type        = string
  default     = "us-central1"
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# --- 1. Enable APIs ---
resource "google_project_service" "apis" {
  for_each = toset([
    "cloudfunctions.googleapis.com",
    "run.googleapis.com",
    "firestore.googleapis.com",
    "aiplatform.googleapis.com",
    "cloudbuild.googleapis.com",
    "eventarc.googleapis.com",
    "iam.googleapis.com",
    "cloudresourcemanager.googleapis.com"
  ])
  service = each.key
  disable_on_destroy = false
}

# --- 2. Firestore Database (Native Mode) ---
resource "google_firestore_database" "database" {
  name        = "(default)"
  location_id = var.region
  type        = "FIRESTORE_NATIVE"
  depends_on  = [google_project_service.apis]
}

# --- 3. Storage Buckets ---
resource "google_storage_bucket" "pdf_bucket" {
  name          = "${var.project_id}-rag-pdfs"
  location      = var.region
  force_destroy = true
  uniform_bucket_level_access = true
}

resource "google_storage_bucket" "source_bucket" {
  name          = "${var.project_id}-rag-source"
  location      = var.region
  force_destroy = true
  uniform_bucket_level_access = true
}

# --- 4. Zip Source Code ---
data "archive_file" "ingest_zip" {
  type        = "zip"
  source_dir  = "../ingest"
  output_path = "/tmp/ingest.zip"
}

resource "google_storage_bucket_object" "ingest_zip" {
  name   = "ingest-${data.archive_file.ingest_zip.output_md5}.zip"
  bucket = google_storage_bucket.source_bucket.name
  source = data.archive_file.ingest_zip.output_path
}

data "archive_file" "retrieve_zip" {
  type        = "zip"
  source_dir  = "../retrieve"
  output_path = "/tmp/retrieve.zip"
}

resource "google_storage_bucket_object" "retrieve_zip" {
  name   = "retrieve-${data.archive_file.retrieve_zip.output_md5}.zip"
  bucket = google_storage_bucket.source_bucket.name
  source = data.archive_file.retrieve_zip.output_path
}

# --- 5. Service Account ---
resource "google_service_account" "rag_sa" {
  account_id   = "rag-app-sa"
  display_name = "RAG Service Account"
}

resource "google_project_iam_member" "sa_roles" {
  for_each = toset([
    "roles/datastore.owner",
    "roles/storage.objectViewer",
    "roles/aiplatform.user",
    "roles/logging.logWriter"
  ])
  role    = each.key
  member  = "serviceAccount:${google_service_account.rag_sa.email}"
  project = var.project_id
}

# --- 6. Cloud Functions ---
# Ingestion
resource "google_cloudfunctions2_function" "ingest_fn" {
  name        = "rag-ingest"
  location    = var.region
  description = "PDF Ingestion"

  build_config {
    runtime     = "python311"
    entry_point = "process_pdf"
    source {
      storage_source {
        bucket = google_storage_bucket.source_bucket.name
        object = google_storage_bucket_object.ingest_zip.name
      }
    }
  }

  service_config {
    max_instance_count = 1
    available_memory   = "512Mi"
    timeout_seconds    = 300
    service_account_email = google_service_account.rag_sa.email
    environment_variables = {
       GCP_PROJECT = var.project_id
    }
  }

  event_trigger {
    trigger_region = var.region
    event_type     = "google.cloud.storage.object.v1.finalized"
    retry_policy   = "RETRY_POLICY_DO_NOT_RETRY"
    service_account_email = google_service_account.rag_sa.email
    event_filters {
      attribute = "bucket"
      value     = google_storage_bucket.pdf_bucket.name
    }
  }
  depends_on = [google_project_service.apis, google_project_iam_member.sa_roles]
}

# Retrieval
resource "google_cloudfunctions2_function" "retrieve_fn" {
  name        = "rag-retrieve"
  location    = var.region

  build_config {
    runtime     = "python311"
    entry_point = "retrieve_and_generate"
    source {
      storage_source {
        bucket = google_storage_bucket.source_bucket.name
        object = google_storage_bucket_object.retrieve_zip.name
      }
    }
  }

  service_config {
    timeout_seconds    = 300	    
    max_instance_count = 5
    available_memory   = "512Mi"
    service_account_email = google_service_account.rag_sa.email
    environment_variables = {
       GCP_PROJECT = var.project_id
    }
  }
  depends_on = [google_project_service.apis, google_project_iam_member.sa_roles]
}

# --- 7. Public Access for Retrieval API ---
resource "google_cloud_run_service_iam_binding" "default" {
  location = google_cloudfunctions2_function.retrieve_fn.location
  service  = google_cloudfunctions2_function.retrieve_fn.name
  role     = "roles/run.invoker"
  members  = ["allUsers"]
}

# --- 8. Firestore Vector Index ---
resource "google_firestore_index" "vector_index" {
  project = var.project_id
  database = "(default)"
  collection = "rag_docs"

  fields {
    field_path = "embedding"
    vector_config {
      dimension = 768
      flat {}
    }
  }
  depends_on = [google_firestore_database.database]
}

# --- 9. Outputs ---
output "api_url" {
  value = google_cloudfunctions2_function.retrieve_fn.service_config[0].uri
}

