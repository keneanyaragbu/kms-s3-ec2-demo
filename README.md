AWS KMS-S3-EC2 IAM Role Demo

Author: Kenechukwu Anyaragbu

Demonstrates how an EC2 instance reads KMS-encrypted objects from S3
using an IAM role — zero hardcoded credentials anywhere in the code.
A single terraform apply provisions the entire chain: KMS key, encrypted
S3 bucket, IAM role with least-privilege permissions, and an EC2 instance
that retrieves and decrypts configuration at boot.


Architecture

┌─────────────────────────────────────────────────────────────┐
│                                                             │
│   KMS Key (customer-managed, auto-rotating)                 │
│       │                                                     │
│       │ encrypts                                            │
│       ▼                                                     │
│   S3 Bucket (all public access blocked)                     │
│       │                                                     │
│       │ contains: config/app.env (encrypted at rest)        │
│       │                                                     │
│       │ reads from (aws s3 cp)                              │
│       │                                                     │
│   EC2 Instance                                              │
│       │                                                     │
│       │ wears                                               │
│       ▼                                                     │
│   IAM Role (via Instance Profile)                           │
│       ├── s3:GetObject    → can reach the file              │
│       ├── s3:ListBucket   → can list the bucket             │
│       └── kms:Decrypt     → can decrypt the file            │
│              + kms:GenerateDataKey → can encrypt new files   │
│                                                             │
└─────────────────────────────────────────────────────────────┘

What Happens at Boot

EC2 boots
  → user_data script runs
  → Installs AWS CLI v2
  → Calls: aws s3 cp s3://<bucket>/config/app.env /opt/app.env
  → AWS CLI finds IAM role via instance metadata (169.254.169.254)
  → Gets temporary credentials from role (auto-rotated every few hours)
  → Calls S3 API with temporary credentials
  → S3 checks IAM: "does this role have s3:GetObject?" → YES
  → S3 sees object is KMS-encrypted
  → S3 calls KMS: "decrypt the data key"
  → KMS checks IAM: "does this role have kms:Decrypt?" → YES
  → KMS decrypts data key → S3 decrypts object → plaintext returned
  → File saved to /opt/app.env
  → Logged to /var/log/kms-demo.log with timestamp

No credentials in code. No keys on disk. No passwords in environment
variables. The IAM role handles everything automatically.


Repository Structure

├── main.tf            # KMS key, S3 bucket, IAM role, EC2 instance
├── variables.tf       # SSH key and allowed CIDR inputs
├── outputs.tf         # Instance IP, bucket name, SSH command
├── README.md          # This file
└── .gitignore         # Excludes state files, .terraform/, keys


Resources Created (12 total)

#ResourcePurpose1aws_kms_keyCustomer-managed encryption key with auto-rotation2aws_kms_aliasFriendly name (alias/app-config-key) for the key3aws_s3_bucketStores the application config file4aws_s3_bucket_server_side_encryption_configurationForces KMS encryption on all objects5aws_s3_bucket_public_access_blockBlocks all public access6aws_s3_objectUploads config/app.env (auto-encrypted by S3)7aws_iam_roleTrust policy allowing EC2 to assume the role8aws_iam_role_policyPermissions: s3:GetObject, s3:ListBucket, kms:Decrypt, kms:GenerateDataKey9aws_iam_instance_profileWraps the role for EC2 attachment10aws_key_pairSSH key pair for instance access11aws_security_groupSSH from your IP only, all outbound allowed12aws_instanceUbuntu 24.04 instance with IAM role and user_data


Usage

Prerequisites


AWS CLI configured (aws sts get-caller-identity)
Terraform installed
SSH key pair generated


Deploy

bash# Generate SSH key
ssh-keygen -t ed25519 -f ~/.ssh/kms-demo-key -N ""

# Deploy everything
terraform init
terraform apply \
  -var="ssh_public_key=$(cat ~/.ssh/kms-demo-key.pub)" \
  -var="ssh_allowed_cidr=$(curl -4 -s ifconfig.me)/32" \
  -auto-approve

Verify

Wait 60 seconds for user_data to finish, then:

bash# SSH into the instance
ssh -i ~/.ssh/kms-demo-key ubuntu@<INSTANCE_IP>

# View the decrypted config
cat /opt/app.env

# Expected output:
#   DB_HOST=prod-database.internal
#   DB_PORT=5432
#   DB_NAME=healthpulse
#   API_KEY=sk-production-secret-key-12345
#   APP_ENV=production

# View the retrieval log
cat /var/log/kms-demo.log

Prove the Role Is Required

Remove the IAM role from the instance:

AWS Console → EC2 → Select instance → Actions → Security → Modify IAM Role → Remove

Then SSH in and try:

bashaws s3 cp s3://<BUCKET_NAME>/config/app.env /tmp/test.env
# FAILS: "Unable to locate credentials"

Re-attach the role, try again — it works. This proves the IAM role is
the sole source of authentication. No role = no access.

Prove KMS Decrypt Is Required

Remove kms:Decrypt from the role policy in main.tf, apply, then SSH in:

bashaws s3 cp s3://<BUCKET_NAME>/config/app.env /tmp/test.env
# FAILS: "AccessDenied" — can reach S3 but cannot decrypt

Add kms:Decrypt back, apply — it works. Two doors (S3 + KMS),
both must be unlocked.

Verify Encryption on the Bucket

From your laptop (not the EC2):

bashaws s3api head-object --bucket <BUCKET_NAME> --key config/app.env
# Look for: "ServerSideEncryption": "aws:kms"
# This confirms the object is encrypted at rest

Destroy

bashterraform destroy \
  -var="ssh_public_key=$(cat ~/.ssh/kms-demo-key.pub)" \
  -var="ssh_allowed_cidr=$(curl -4 -s ifconfig.me)/32" \
  -auto-approve


IAM Permissions Explained

PermissionWhat it allowsWhy it's neededs3:GetObjectDownload objects from the bucketEC2 needs to read the config files3:ListBucketList objects in the bucketEC2 needs to discover what files existkms:DecryptDecrypt data encrypted with the KMS keyS3 objects are KMS-encrypted; without this, download succeeds but decryption failskms:GenerateDataKeyGenerate a temporary data key for encrypting new objectsNeeded if EC2 writes encrypted objects back to S3

Least Privilege Matrix

EC2 needs to...Required permissionsRead encrypted objectss3:GetObject + kms:DecryptWrite encrypted objectss3:PutObject + kms:GenerateDataKeyList bucket contentss3:ListBucketDelete objectss3:DeleteObject (no KMS needed)


KMS Concepts Demonstrated

Envelope Encryption

KMS does not encrypt your 10MB file directly. Instead:

KMS Master Key → encrypts → small Data Key
                              │
                         Data Key → encrypts → your actual file

To decrypt:
KMS Master Key → decrypts → Data Key → decrypts → your file

The master key never leaves KMS. Only the small data key is transmitted.
This is faster and more secure than sending large files to KMS.

Key Rotation

enable_key_rotation = true in the KMS key resource means AWS
automatically creates new key material every year. Old key material
is preserved for decrypting data encrypted with previous versions.
The key ID and ARN stay the same — no code changes needed.

Bucket Keys

bucket_key_enabled = true on the S3 encryption configuration
reduces KMS API calls. Without it, every S3 object operation calls
KMS individually. With it, S3 generates a bucket-level key from
KMS once and reuses it for multiple objects. At scale, this saves
thousands of dollars in KMS request charges.


Cost

ComponentCostKMS key storage$1/month (prorated hourly)KMS API requests$0.03 per 10,000 (first 20,000/month free forever)EC2 t3.micro~$0.01/hourS3 storageNegligible (one small file)Demo total< $0.01 (everything exists for minutes)


Issues and Resolutions

Issue 1: IPv6 Address Rejected by Security Group

Error:

"2600:8800:3e80:ab00:cd84:4f76:62b:10c0/32" is not a valid IPv4 CIDR block

Cause: curl ifconfig.me returned an IPv6 address. The network
preferred IPv6 over IPv4 at that moment. AWS security group cidr_blocks
only accepts IPv4.

Resolution: Force IPv4 with the -4 flag:

bashcurl -4 -s ifconfig.me

Issue 2: AWS CLI Package Not Available on Ubuntu 24.04

Error:

Package awscli is not available, but is referred to by another package.
E: Package 'awscli' has no installation candidate

Cause: Ubuntu 24.04 removed the awscli package from its default
repositories. The apt install -y awscli command worked on older Ubuntu
versions but fails on 24.04.

Resolution: Install AWS CLI v2 from Amazon's official installer
instead of apt:

bashcurl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "/tmp/awscliv2.zip"
unzip -q /tmp/awscliv2.zip -d /tmp
/tmp/aws/install

Use full path /usr/local/bin/aws in scripts since PATH may not be
set during user_data execution.

Issue 3: KMS Key Policy Circular Reference

Cause: The KMS key policy references aws_iam_role.app_role.arn,
but the role is defined in the same Terraform configuration. Terraform
must create the role before the key, which it handles automatically
through implicit dependency resolution.

Resolution: Terraform's dependency graph resolves this — no manual
intervention needed. The role is created first, then the KMS key
references its ARN. If using separate Terraform modules, pass the
role ARN as a variable instead of referencing directly.


Security Best Practices Demonstrated

PracticeHow it's implementedNo hardcoded credentialsIAM role provides temporary credentials via instance metadataEncryption at restS3 server-side encryption with customer-managed KMS keyLeast privilegeRole has only s3:GetObject, s3:ListBucket, kms:Decrypt, kms:GenerateDataKeyKey rotationKMS auto-rotates key material annuallyNetwork restrictionSecurity group allows SSH from deployer's IP onlyPublic access blockedS3 bucket blocks all public access at every levelNo secrets in GitVariables injected at runtime via -var flag, .gitignore excludes state and keys


Technologies

TechnologyPurposeTerraformInfrastructure as Code — provisions all 12 resourcesAWS KMSKey management and encryptionAWS S3Encrypted object storageAWS IAMRole-based access control with least privilegeAWS EC2Compute instance demonstrating role assumptionAWS CLI v2Reads S3 from the instance using role credentials


Author

Kenechukwu Anyaragbu