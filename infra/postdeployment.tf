/**
 * Copyright 2023 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

locals {
  random_suffix_value = var.random_suffix ? random_id.suffix.hex : ""          # literal value  (NNNN)
  random_suffix_append =  var.random_suffix ? "-${random_id.suffix.hex}" : ""  # appended value (-NNNN)

  setup_job_name = "setup${local.random_suffix_append}"

  gcloud_step_container = "gcr.io/google.com/cloudsdktool/cloud-sdk:slim"
  curl_step_container = "gcr.io/distroless/static-debian11"
}

# used to collect access token, for authenticated POST commands
data "google_client_config" "current" {
}

# topic that is never used, except as a configuration type for Cloud Build Triggers
resource "google_pubsub_topic" "faux" {
  name = "faux-topic${local.random_suffix_append}"
}

## Placeholder - deploys a placeholder website - uses prebuilt image in /app/placeholder
resource "google_cloudbuild_trigger" "placeholder" {
  name     = "placeholder${local.random_suffix_append}"
  location = "us-central1"

  description = "Deploy a placeholder Firebase website"

  service_account = google_service_account.client.id

  pubsub_config {
    topic = google_pubsub_topic.faux.id
  }

  build {
    step {
      name = local.placeholder_image
      env = [
        "PROJECT_ID=${var.project_id}",
        "SUFFIX=${local.random_suffix_value}",
        "FIREBASE_URL=${local.firebase_url}",
      ]
    }

    options {
      logging = "CLOUD_LOGGING_ONLY"
    }
  }
}


# execute the trigger, once it and other dependencies exist. Intended side-effect.
# tflint-ignore: terraform_unused_declarations
data "http" "execute_placeholder_trigger" {
  count = var.init ? 1 : 0

  url    = "https://cloudbuild.googleapis.com/v1/${google_cloudbuild_trigger.placeholder.id}:run"
  method = "POST"
  request_headers = {
    Authorization = "Bearer ${data.google_client_config.current.access_token}"
  }
  depends_on = [
    module.project_services,
    google_cloudbuild_trigger.placeholder
  ]
}


## Initalization trigger
resource "google_cloudbuild_trigger" "init" {
  name     = "init-application${local.random_suffix_append}"
  location = var.region

  description = "Perform initialization setup for server and client"

  pubsub_config {
    topic = google_pubsub_topic.faux.id
  }

  service_account = google_service_account.init[0].id

  build {
    step {
      # Check if a job already exists under the exact name. If it doesn't, create it. 
      id     = "create-setup-job"
      name   = local.gcloud_step_container
      script = <<EOT
#!/bin/bash
SETUP_JOB=$(gcloud run jobs list --filter "metadata.name~${local.setup_job_name}$" --format "value(metadata.name)" --region ${var.region})

if [[ -z $SETUP_JOB ]]; then
  echo "Creating ${local.setup_job_name} Cloud Run Job"
gcloud run jobs create ${local.setup_job_name} --region ${var.region} \
 --command migrate \
 --image ${local.server_image} \
 --service-account ${google_service_account.automation.email} \
 --set-secrets DJANGO_ENV=${google_secret_manager_secret.django_settings.secret_id}:latest \
 --set-secrets DJANGO_SUPERUSER_PASSWORD=${google_secret_manager_secret.django_admin_password.secret_id}:latest \
 --set-cloudsql-instances ${google_sql_database_instance.postgres.connection_name}
else
  echo "Cloud Run Job ${local.setup_job_name} already exists."
fi
EOT
    }
    # Now that the job definitely exists, execute it.
    step { 
      id = "execute-setup-job"
      name = local.gcloud_step_container
      script = "gcloud run jobs execute ${local.setup_job_name} --wait --region ${var.region} --project ${var.project_id}"
    }

    # Instead of creating a client job then executing it, execute the container itself. 
    # This container doesn't require additional Cloud SQL configurations like the server container, so it can be run directly
    # rather than creating a job first. 
    step {
      id   = "client-setup"
      name = local.client_image
      env = [
        "PROJECT_ID=${var.project_id}",
        "SUFFIX=${var.random_suffix ? random_id.suffix.hex : ""}",
        "REGION=${var.region}",
        "FIREBASE_URL=${local.firebase_url}",
      ]
    }

    # Ensure any cached versions of the application are purged 
    step {
      id     = "purge-firebase"
      name   = local.curl_step_container
      script = "curl -X PURGE \"${local.firebase_url}/\""
    }

    # Preemptively warm up the server API
    step {
      id     = "warmup-api"
      name   = local.curl_step_container
      script = "curl \"${google_cloud_run_v2_service.server.uri}/api/products/?warmup\""
    }

    options {
      logging = "CLOUD_LOGGING_ONLY"
    }
  }
}

# execute the trigger, once it and other dependencies exist. Intended side-effect.
# tflint-ignore: terraform_unused_declarations
data "http" "execute_init_trigger" {
  count = var.init ? 1 : 0

  url    = "https://cloudbuild.googleapis.com/v1/${google_cloudbuild_trigger.init.id}:run"
  method = "POST"
  request_headers = {
    Authorization = "Bearer ${data.google_client_config.current.access_token}"
  }
  depends_on = [
    module.project_services,
    google_sql_database_instance.postgres,
    google_cloudbuild_trigger.init,
  ]
}
