
terraform {
  required_version = ">=0.14"
  required_providers {
    google      = "~> 3.0"
    google-beta = "~> 3.0"
  }

}

resource "random_id" "suffix" {
  byte_length = 2
}

locals {

  project_name      = format("%s-%s", var.project_prefix, var.project_name)
  project_id        = format("%s-%s-%s", var.project_prefix, var.project_name, random_id.suffix.hex)
  state_bucket_name = format("bkt-%s-%s", "tfstate", local.project_id)
  art_bucket_name   = format("bkt-%s-%s", "artifacts", local.project_id)
  repo_name         = format("src-%s", local.project_name)
  gar_repo_name     = format("%s-%s", var.project_prefix, "containers")
  is_organization   = var.parent_folder == "" ? true : false
  parent_id         = var.parent_folder == "" ? var.org_id : split("/", var.parent_folder)[1]
  project_org_id    = var.folder_id != "" ? null : var.org_id
  project_folder_id = var.folder_id != "" ? var.folder_id : null
  cloudbuild_sa     = "serviceAccount:${google_project.cicd.number}@cloudbuild.gserviceaccount.com"
  services = [
    "cloudbilling.googleapis.com",
    "cloudbuild.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "compute.googleapis.com",
    "iam.googleapis.com",
    "servicenetworking.googleapis.com",
    "serviceusage.googleapis.com",
    "sourcerepo.googleapis.com",
    "appengine.googleapis.com",
    "cloudscheduler.googleapis.com",
    "run.googleapis.com",
    "containerregistry.googleapis.com",
    "artifactregistry.googleapis.com",
    "orgpolicy.googleapis.com",
    "secretmanager.googleapis.com",
    "aiplatform.googleapis.com"
  ]
  cloudbuild_sa_viewer_roles = [
    "roles/browser",
    "roles/iam.securityReviewer",
    "roles/secretmanager.secretViewer",
    "roles/secretmanager.secretAccessor",
  ]
  cloudbuild_sa_editor_roles = [
    "roles/compute.xpnAdmin",
    "roles/logging.configWriter",
    "roles/resourcemanager.projectCreator",
    "roles/resourcemanager.organizationAdmin",
    "roles/orgpolicy.policyAdmin",
    "roles/resourcemanager.folderCreator",
  ]
  cloudbuild_roles = [
    # Allow CICD to view all resources within the project so it can run terraform plans against them.
    # It won't be able to actually apply any changes unless granted the permission in this list.
    "roles/editor",

    # Enable Cloud Build SA to list and enable APIs in the project.
    # and set cloud run IAM policy
    "roles/serviceusage.serviceUsageAdmin",
    "roles/run.admin"
  ]
}


resource "google_project" "cicd" {
  name                = local.project_name
  project_id          = local.project_id
  org_id              = local.project_org_id
  folder_id           = local.project_folder_id
  billing_account     = var.billing_account
  auto_create_network = var.auto_create_network
  labels              = var.project_labels
}
# bucket for terraform state
resource "google_storage_bucket" "project_terraform_state" {
  project                     = google_project.cicd.project_id
  name                        = local.state_bucket_name
  location                    = var.default_region
  uniform_bucket_level_access = true
  force_destroy               = true
  versioning {
    enabled = true
  }
}

# Cloud Build - API
resource "google_project_service" "services" {
  for_each           = toset(local.services)
  project            = google_project.cicd.project_id
  service            = each.value
  disable_on_destroy = false
}

# IAM permissions to allow contributors to view the cloud build jobs.
resource "google_project_iam_member" "cloudbuild_builds_viewers" {
  for_each = toset(var.cloudbuild_viewers)
  project  = google_project.cicd.project_id
  role     = "roles/cloudbuild.builds.viewer"
  member   = each.value
  depends_on = [
    google_project_service.services,
  ]
}

# IAM permissions to allow approvers to edit/create the cloud build jobs.
resource "google_project_iam_member" "cloudbuild_builds_editors" {
  for_each = toset(var.cloudbuild_editors)
  project  = google_project.cicd.project_id
  role     = "roles/cloudbuild.builds.editor"
  member   = each.value
  depends_on = [
    google_project_service.services,
  ]
}

# IAM permissions to allow approvers and contributors to view logs.
# https://cloud.google.com/cloud-build/docs/securing-builds/store-view-build-logs
resource "google_project_iam_member" "cloudbuild_logs_viewers" {
  for_each = toset(concat(var.cloudbuild_viewers, var.cloudbuild_editors))
  project  = google_project.cicd.project_id
  role     = "roles/viewer"
  member   = each.value
  depends_on = [
    google_project_service.services,
  ]
}

# Create the Cloud Source Repository.
resource "google_sourcerepo_repository" "configs" {
  project = google_project.cicd.project_id
  name    = local.repo_name
  depends_on = [
    google_project_service.services,
  ]
}

resource "google_sourcerepo_repository_iam_member" "readers" {
  for_each   = toset(var.cloudbuild_viewers)
  project    = google_project.cicd.project_id
  repository = google_sourcerepo_repository.configs.name
  role       = "roles/source.reader"
  member     = each.key
}

resource "google_sourcerepo_repository_iam_member" "writers" {
  for_each   = toset(var.cloudbuild_editors)
  project    = google_project.cicd.project_id
  repository = google_sourcerepo_repository.configs.name
  role       = "roles/source.writer"
  member     = each.key
}

# Grant Cloud Build Service Account access to the  project.
resource "google_project_iam_member" "cloudbuild_sa_project_iam" {
  for_each = toset(local.cloudbuild_roles)
  project  = google_project.cicd.project_id
  role     = each.key
  member   = local.cloudbuild_sa
  depends_on = [
    google_project_service.services,
  ]
}

# Cloud Scheduler resources.
# Cloud Scheduler requires an App Engine app created in the project.
# App Engine app cannot be destroyed once created, therefore always create it.
resource "google_app_engine_application" "cloudbuild_scheduler_app" {
  project     = google_project.cicd.project_id
  location_id = "us-east1"
  depends_on = [
    google_project_service.services,
  ]
}

# Service Account and its IAM permissions used for Cloud Scheduler to schedule Cloud Build triggers.
resource "google_service_account" "cloudbuild_scheduler_sa" {
  project      = google_project.cicd.project_id
  account_id   = "cloudbuild-scheduler-sa"
  display_name = "Cloud Build scheduler service account"
  depends_on = [
    google_project_service.services,
  ]
}

resource "google_project_iam_member" "cloudbuild_scheduler_sa_project_iam" {
  project = google_project.cicd.project_id
  role    = "roles/cloudbuild.builds.editor"
  member  = "serviceAccount:${google_service_account.cloudbuild_scheduler_sa.email}"
  depends_on = [
    google_project_service.services,
  ]
}

# Cloud Build - Cloud Build Service Account IAM permissions

# IAM permissions to allow Cloud Build Service Account use the billing account.
resource "google_billing_account_iam_member" "binding" {
  billing_account_id = var.billing_account
  role               = "roles/billing.user"
  member             = local.cloudbuild_sa
  depends_on = [
    google_project_service.services,
  ]
}

# IAM permissions to allow Cloud Build SA to access state.
resource "google_storage_bucket_iam_member" "cloudbuild_state_iam" {
  bucket = local.state_bucket_name
  role   = "roles/storage.admin"
  member = local.cloudbuild_sa
  depends_on = [
    google_project_service.services, google_storage_bucket.project_terraform_state
  ]
}


# cloudbuild artifiact bucket/permissions/artifact repository

resource "google_storage_bucket" "cloudbuild_artifacts" {
  project                     = google_project.cicd.project_id
  name                        = local.art_bucket_name
  location                    = var.default_region
  uniform_bucket_level_access = true
  force_destroy               = true
  versioning {
    enabled = true
  }
}

resource "google_storage_bucket_iam_member" "cloudbuild_artifacts_iam" {
  bucket = google_storage_bucket.cloudbuild_artifacts.name
  role   = "roles/storage.admin"
  member = local.cloudbuild_sa
}


resource "google_artifact_registry_repository" "image-repo" {
  provider = google-beta
  project  = google_project.cicd.project_id

  location      = var.default_region
  repository_id = local.gar_repo_name
  description   = "Docker repository for images used by Cloud Build"
  format        = "DOCKER"
}

resource "google_artifact_registry_repository_iam_member" "terraform-image-iam" {
  provider = google-beta
  project  = google_project.cicd.project_id

  location   = google_artifact_registry_repository.image-repo.location
  repository = google_artifact_registry_repository.image-repo.name
  role       = "roles/artifactregistry.writer"
  member     = local.cloudbuild_sa
  depends_on = [
    google_artifact_registry_repository.image-repo
  ]
}
