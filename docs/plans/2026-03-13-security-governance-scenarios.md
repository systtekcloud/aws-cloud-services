# Security & Governance Scenarios SAA-C03 — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Create 10 exam-style SAA-C03 scenarios for Security & Governance multi-account in two separate files (questions + answers), matching the format established in compute/scenarios/.

**Architecture:** Two markdown files in `security/scenarios/`. Questions file is "blind" (no answers). Answers file has full explanations, wrong-answer analysis, and exam tips. Same structure as `compute/scenarios/compute-scenarios-sa-associate.md`.

**Tech Stack:** Markdown only. No code. No diagrams.

---

## Reference Files

- **Format reference (questions):** `compute/scenarios/compute-scenarios-sa-associate.md`
- **Format reference (answers):** `compute/scenarios/compute-scenarios-sa-associate-answers.md`
- **Output questions:** `security/scenarios/security-scenarios-sa-associate.md`
- **Output answers:** `security/scenarios/security-scenarios-sa-associate-answers.md`

---

## Conditions That Must Be Met (verify at end)

- [ ] ≥ 2 scenarios where correct answer is SCP/OU design and distractor is IAM policy
- [ ] 1 scenario: Identity Center vs IAM Users (federated access)
- [ ] 1 scenario: CloudTrail org-level vs Config (audit vs compliance) at org level
- [ ] 1 scenario: Control Tower guardrails vs manual Organizations implementation
- [ ] 1 scenario: KMS + Secrets Manager → AccessDenied typical in multi-account
- [ ] All 10 scenarios have: 2-3 paragraph business problem, technical requirements, 4 options A-D
- [ ] Answers file has: correct answer, detailed explanation, why each wrong answer fails in prod, exam tip
- [ ] Answers file cross-links to questions file and vice versa

---

## Scenario Distribution

| # | Industry | Main Pattern | Compliance | Mandatory Condition |
|---|----------|--------------|------------|---------------------|
| 1 | Fintech | SCP/OU design — approved regions per OU vs IAM policy | PCI-DSS | SCP/OU #1 |
| 2 | Retail | SCP/OU design — CloudTrail protection at org level vs IAM | — | SCP/OU #2 |
| 3 | Healthcare | IAM Identity Center vs IAM Users — federated multi-account | HIPAA | IDC vs Users |
| 4 | Media | CloudTrail org-level vs Config — audit event vs compliance state | — | CloudTrail vs Config |
| 5 | SaaS Enterprise | Control Tower guardrails vs manual Organizations | — | CT vs manual |
| 6 | Banking | KMS + Secrets Manager — AccessDenied cross-account decrypt | PCI-DSS | KMS multi-account |
| 7 | E-Commerce | SSM Session Manager vs bastion — no static keys | — | Secure ops access |
| 8 | Pharma | RAM (Resource Access Manager) — sharing resources across accounts | GxP | Extra typical |
| 9 | Insurance | Access Analyzer — unintended external access findings | SOC2 | Extra typical |
| 10 | Government | Permission boundaries — privilege delegation without escalation | FedRAMP | Extra typical |

---

## Task 1: Create directory and questions file skeleton

**Files:**
- Create: `security/scenarios/security-scenarios-sa-associate.md`

**Step 1: Create the security/scenarios/ directory**

```bash
mkdir -p security/scenarios
```

**Step 2: Create the questions file with header, cross-link, and index table**

Header format (copy from compute reference):
```markdown
# Security & Governance — Escenarios SAA-C03

> 10 escenarios de arquitectura estilo examen real. Multi-cuenta, Organizations, SCP, Identity Center y más.
> Las respuestas están en: [security-scenarios-sa-associate-answers.md](./security-scenarios-sa-associate-answers.md)

---

## Índice

| # | Industria | Patrón principal | Compliance |
|---|-----------|-----------------|------------|
| [1](#escenario-1) | Fintech | SCP/OU — restricción de regiones por OU vs IAM policy | PCI-DSS |
| [2](#escenario-2) | Retail | SCP/OU — protección de CloudTrail org-level vs IAM | — |
| [3](#escenario-3) | Healthcare | IAM Identity Center vs IAM Users — acceso federado multi-cuenta | HIPAA |
| [4](#escenario-4) | Media | CloudTrail org vs Config — auditoría de eventos vs compliance de estado | — |
| [5](#escenario-5) | SaaS Enterprise | Control Tower guardrails vs Organizations manual — baseline governance | — |
| [6](#escenario-6) | Banking | KMS + Secrets Manager — AccessDenied cross-account decrypt | PCI-DSS |
| [7](#escenario-7) | E-Commerce | SSM Session Manager vs bastion — acceso operativo sin claves estáticas | — |
| [8](#escenario-8) | Pharma | RAM — compartir recursos entre cuentas sin duplicarlos | GxP |
| [9](#escenario-9) | Insurance | Access Analyzer — findings de acceso externo no intencionado | SOC2 |
| [10](#escenario-10) | Government | Permission boundaries — delegación sin escalada de privilegios | FedRAMP |

---
```

**Step 3: Verify file exists and has correct structure**

Check: file exists, has title, has index table with 10 rows, has cross-link to answers file.

---

## Task 2: Write Scenarios 1–2 (SCP/OU conditions) in questions file

**Files:**
- Modify: `security/scenarios/security-scenarios-sa-associate.md`

**Scenario 1 — Fintech / SCP region restriction (SCP/OU #1)**

Business context:
- Fintech under PCI-DSS with multi-account org
- Security team must enforce that workload accounts ONLY deploy to eu-west-1
- A developer in the Dev account deploys an RDS instance in ap-southeast-1 by mistake
- They tried IAM permission boundaries to restrict regions, but it didn't work for all services
- Need to understand WHY the IAM approach failed and what the correct preventive control is

Technical requirements:
- All member accounts in Workloads OU: no resource creation outside eu-west-1
- Global services (IAM, CloudFront, Route 53, STS) must continue working
- No impact on Management Account
- The restriction must be impossible to override from within the member account

Options (A-D distractors):
- A) Correct: SCP on Workloads OU with `NotAction` for global services + `StringNotEquals` on `aws:RequestedRegion`
- B) Distractor: IAM Permission Boundary on each IAM role/user with region condition
- C) Distractor: AWS Config rule "approved-regions" with auto-remediation to delete out-of-region resources
- D) Distractor: Tag policy on the OU requiring `Region=eu-west-1` tag on all resources

**Scenario 2 — Retail / SCP CloudTrail protection (SCP/OU #2)**

Business context:
- Retail company with 15 AWS accounts under Organizations
- SOC2 audit requires immutable audit trail
- A developer with Admin access in a member account accidentally ran `aws cloudtrail stop-logging`
- The security team wants a preventive control so that even account Admins cannot disable CloudTrail
- They considered using IAM policies that deny CloudTrail actions, but the issue is who manages those policies

Technical requirements:
- CloudTrail must be impossible to stop/delete/modify from any member account
- Even the account's root user equivalent (non-management account) must be blocked
- Control must apply automatically to new accounts added to the org
- Must NOT affect the Management Account (which manages the org trail)

Options (A-D distractors):
- A) Distractor: IAM policy attached to all roles in each account denying `cloudtrail:StopLogging`
- B) Distractor: AWS Config rule that remediates (re-enables) CloudTrail if stopped
- C) Correct: SCP at Root level denying `cloudtrail:StopLogging`, `cloudtrail:DeleteTrail`, `cloudtrail:UpdateTrail`
- D) Distractor: CloudTrail log file validation + S3 Object Lock to ensure logs can't be deleted

**Step 1: Write both scenarios in full** — each with 2-3 paragraph business problem, technical requirements block, and options A-D. No answers or hints.

**Step 2: Verify**

- Scenario 1: IAM Permission Boundary is option B (wrong), SCP is option A (not marked as correct)
- Scenario 2: IAM policy denial is option A (wrong), SCP is option C (not marked as correct)
- No answer keys, no bold "correct answer" anywhere in questions file

---

## Task 3: Write Scenarios 3–5 in questions file

**Files:**
- Modify: `security/scenarios/security-scenarios-sa-associate.md`

**Scenario 3 — Healthcare / IDC vs IAM Users**

Business context:
- Hospital network with 8 AWS accounts (1 management + 7 workload)
- 45 engineers need access with different permission levels per account
- Currently: individual IAM users in each account → 45 × 8 = 360 IAM users to manage
- Audit finding: 12 former employees still have active IAM users in some accounts
- HIPAA requires centralized access management and audit trail of who accessed what
- No existing IdP: the company wants to use AWS-native solution

Technical requirements:
- Single place to create/remove users → removing a user blocks access to ALL accounts simultaneously
- Each engineer gets different permissions per account (e.g., DevPowerUser in Dev, ReadOnly in Prod)
- No static long-term AWS credentials (no access keys for console/CLI access)
- MFA enforcement
- Audit log of all console and CLI sessions

Options (A-D distractors):
- A) Distractor: Create IAM users in the Management Account and use cross-account IAM roles with trust policy
- B) Correct: Enable IAM Identity Center, create users in Identity Store, create Permission Sets, create Account Assignments
- C) Distractor: Use AWS Directory Service Managed Microsoft AD and configure SAML federation per account
- D) Distractor: Create IAM users in each account but use AWS SSO (deprecated) for centralized password management

**Scenario 4 — Media / CloudTrail vs Config**

Business context:
- Media company under SOC2 Type II with 6 AWS accounts
- Security team receives two different alerts and is confused about which tool answers which question
- Alert 1: "An S3 bucket was made public at 14:32 UTC — who did it and from which IP?"
- Alert 2: "We need to know which S3 buckets are currently public RIGHT NOW across all 6 accounts"
- Alert 3: "We need a report of every time a bucket's public-access setting changed in the last 90 days"
- Team is debating whether to use CloudTrail or Config (or both) for each use case

Technical requirements:
- Multi-account: all 6 accounts must be covered
- CloudTrail org-level trail already exists (Management Account)
- Need to add Config for the missing capability
- Minimize operational overhead (no per-account manual setup)

Options:
- A) Distractor: CloudTrail answers all 3 questions — search CloudTrail for `PutBucketAcl` events for alerts 1, 2, and 3
- B) Distractor: Config answers all 3 questions — Config tracks resource state changes including who made the change
- C) Distractor: Use GuardDuty for alert 1 (anomaly detection catches unauthorized access) and Config for alerts 2-3
- D) Correct: CloudTrail answers alert 1 (who/when/IP = API call audit). Config answers alert 2 (current state = compliance snapshot) and alert 3 (configuration history). Both needed together. Config aggregator at org level for multi-account.

**Scenario 5 — SaaS Enterprise / Control Tower vs manual**

Business context:
- SaaS startup growing from 2 to 12 AWS accounts over 6 months
- CTO wants to ensure every new account has: org-level CloudTrail, no public S3, no root account activity, MFA required for console
- Options on the table: (a) Control Tower, (b) manual setup of Organizations + SCPs + IAM + Config
- Engineering team argues that Control Tower "does too much magic" and they want control
- Security team wants guardrails to be automatically applied to every new account
- Timeline: 4 new accounts need to be provisioned this sprint

Technical requirements:
- Baseline security controls applied automatically to every new account
- Audit account and Log Archive account automatically created
- Minimal operational overhead for the security team
- New accounts provisioned via self-service (developers shouldn't need to ask ops to create an account)

Options:
- A) Distractor: Use AWS Organizations + manual SCPs + manual IAM + manual Config setup per account. Gives full control.
- B) Distractor: Use CloudFormation StackSets to deploy security baseline to each new account after creation
- C) Distractor: Use Service Catalog to create a product that engineers can launch to create new accounts with baseline
- D) Correct: Use Control Tower — creates Log Archive + Audit accounts automatically, applies preventive guardrails (SCPs) and detective guardrails (Config Rules), Account Factory for self-service account vending, all baseline enforced automatically

---

## Task 4: Write Scenarios 6–7 in questions file

**Files:**
- Modify: `security/scenarios/security-scenarios-sa-associate.md`

**Scenario 6 — Banking / KMS + Secrets Manager AccessDenied**

Business context:
- Bank with Security account (owns KMS keys) and App account (runs EC2 workloads)
- Security team created a KMS Customer Managed Key in the Security account for encrypting DB credentials
- App team stored DB credentials in Secrets Manager in the App account, encrypted with the cross-account KMS key
- EC2 instance in the App account has an IAM Role with `secretsmanager:GetSecretValue` permission
- When the application calls `GetSecretValue`, it gets `AccessDenied` on the KMS decrypt step
- The IAM Role policy looks correct — it has the Secrets Manager permission

Technical requirements:
- EC2 in App account must be able to read the secret
- KMS key stays in Security account (centralized key management)
- No changes to the KMS key's AWS default key policy structure
- Minimal permissions (no `kms:*` wildcard)

Options:
- A) Distractor: Add `kms:Decrypt` to the IAM Role policy in the App account (points to the cross-account KMS key ARN)
- B) Distractor: Move the KMS key to the App account so there's no cross-account issue
- C) Distractor: Use AWS managed key (`aws/secretsmanager`) instead of CMK — AWS managed keys work cross-account automatically
- D) Correct: BOTH are required: (1) Add `kms:Decrypt` to the IAM Role policy in the App account AND (2) Add the App account's IAM Role (or `arn:aws:iam::APP_ACCOUNT_ID:root`) as a principal in the KMS Key Policy in the Security account. Cross-account KMS requires permission on both sides.

**Scenario 7 — E-Commerce / SSM Session Manager vs bastion**

Business context:
- E-commerce platform with EC2 fleet in private subnets (no internet gateway in the subnet route table)
- Currently uses a bastion host in a public subnet with SSH keypairs
- Problems: SSH keypairs shared between 5 engineers, audit log shows "root" for all sessions (no individual attribution), one engineer left and the team is not sure if they revoked all access
- Security team wants: individual session attribution, no SSH port open anywhere, no static credentials, full session recording
- Compliance: PCI-DSS requires audit trail per individual user, not shared credentials

Technical requirements:
- Remove SSH and bastion host entirely
- Individual user attribution per session (IAM identity)
- Session logs stored in S3 and/or CloudWatch Logs
- No inbound rules (port 22 or any) needed on EC2 security group
- Works for EC2 in private subnets with no internet access

Options:
- A) Distractor: Keep bastion host but replace SSH with EC2 Instance Connect — still gives individual attribution and removes keypairs
- B) Distractor: Use AWS Systems Manager Session Manager with internet access from the EC2 (NAT Gateway required)
- C) Correct: SSM Session Manager with VPC Endpoints for `ssm`, `ssmmessages`, `ec2messages` — no internet needed, no port 22, IAM-authenticated, session logging to S3/CW, individual attribution via IAM Identity Center
- D) Distractor: Use AWS CloudShell to connect to private EC2 instances — CloudShell can access AWS APIs but cannot SSH into private EC2

---

## Task 5: Write Scenarios 8–10 in questions file

**Files:**
- Modify: `security/scenarios/security-scenarios-sa-associate.md`

**Scenario 8 — Pharma / RAM**

Business context:
- Pharmaceutical company with 4 accounts: Shared Services, Dev, Staging, Prod
- Shared Services account has: a Transit Gateway, a VPC with private DNS (Route 53 Resolver), and a licensed third-party security scanner AMI
- Currently the Dev, Staging, and Prod teams have copies of the AMI (billed 3x the license), each account has its own TGW attachment (expensive), and DNS resolution is duplicated per account
- The CTO wants to reduce costs and operational overhead by sharing these resources
- Compliance (GxP) requires that shared resources have a clear ownership chain and audit trail

Technical requirements:
- Share TGW across accounts without deploying one per account
- Share the licensed AMI without copying it (single license)
- Share Route 53 Resolver rules for private DNS resolution across accounts
- Sharing must be within the same AWS Organization (no external sharing)
- Resources must remain owned and managed by Shared Services account

Options:
- A) Distractor: Deploy the TGW and AMI in each account. Use AWS Marketplace to buy one AMI license per account. Use Route 53 Resolver outbound endpoints per account.
- B) Distractor: Use VPC Peering between Shared Services and each workload account. Share AMIs manually with `ec2:ModifyImageAttribute --launch-permission`.
- C) Distractor: Use CloudFormation StackSets to deploy identical resources in each account from a central template.
- D) Correct: Use AWS Resource Access Manager (RAM) to share the Transit Gateway, AMI, and Route 53 Resolver rules from Shared Services account with the entire AWS Organization. RAM enables resource sharing without resource duplication, supports org-level sharing, and maintains resource ownership in the source account.

**Scenario 9 — Insurance / Access Analyzer**

Business context:
- Insurance company with SOC2 Type II. All S3 buckets must be private. No cross-account access unless explicitly documented and approved by the security board.
- Quarterly security audit found: 3 S3 buckets with resource-based policies granting access to external AWS accounts (outside the org), 1 IAM role with a trust policy allowing assume-role from an unknown external account, 1 KMS key policy allowing decryption from a third-party account no longer used
- The security team wants an automated mechanism to catch these issues continuously, not just during quarterly audits

Technical requirements:
- Continuous monitoring of resource-based policies (S3, IAM roles, KMS keys, SQS, Lambda, Secrets Manager)
- Distinguish between "known trusted" external access (documented and approved) and unintended external access
- Cover all accounts in the organization from a single pane of glass
- Alert when a new unintended external access finding is created

Options:
- A) Distractor: Use AWS Config rule `s3-bucket-public-read-prohibited` and `iam-no-inline-policy-check` across all accounts
- B) Distractor: Use Amazon Macie to continuously scan S3 buckets for sensitive data and access policy violations
- C) Distractor: Use AWS Security Hub with the AWS Foundational Security Best Practices standard enabled
- D) Correct: Use AWS IAM Access Analyzer with an Organization Analyzer. It continuously analyzes resource-based policies and generates findings for any resource accessible from outside the organization or from external principals. Archive approved findings to distinguish known-good from unintended access. Integrates with EventBridge for automated alerting.

**Scenario 10 — Government / Permission Boundaries**

Business context:
- Government agency (FedRAMP Moderate) with a central Platform team that owns the AWS accounts
- Application teams need to create their own IAM roles for their Lambda functions and EC2 instances
- Problem: if application teams can create IAM roles, they could create a role with `AdministratorAccess` and escalate privileges
- The Platform team wants to allow application teams to create IAM roles, but prevent them from creating roles with more permissions than the application teams themselves have
- SCPs won't work here because the restriction is at the IAM user/developer level, not at the account level

Technical requirements:
- Application team members can create IAM roles for their workloads
- Created roles cannot have more permissions than the permission boundary allows (e.g., no IAM actions, no billing actions)
- If an application team member tries to create a role without attaching the required permission boundary, the action is denied
- This must be enforceable even if the application team member has broad IAM:CreateRole permissions

Options:
- A) Distractor: Use SCPs to prevent application teams from creating IAM roles with `AdministratorAccess` policy attached
- B) Distractor: Give application teams read-only IAM access — have the Platform team create all IAM roles on their behalf
- C) Distractor: Use IAM policy conditions `iam:PermissionsBoundary` to require a specific boundary ARN when creating roles, and attach that same boundary to the application team members' own IAM entities
- D) Correct: Same as C but correctly explained — use `iam:PermissionsBoundary` condition key in the application team's IAM policy. The condition requires that any `iam:CreateRole` or `iam:PutRolePolicy` call MUST include `PermissionsBoundary=arn:aws:iam::ACCOUNT:policy/AppTeamBoundary`. The boundary policy limits what the created roles can do. Without the boundary, `CreateRole` is denied. Option C is correct — A (SCP) cannot check what policies are attached to roles being created in fine-grained ways, and B breaks developer autonomy.

---

## Task 6: Create answers file

**Files:**
- Create: `security/scenarios/security-scenarios-sa-associate-answers.md`

**Step 1: Create answers file with header and cross-link**

```markdown
# Security & Governance — Respuestas SAA-C03

> Respuestas a: [security-scenarios-sa-associate.md](./security-scenarios-sa-associate.md)
> **No abrir hasta haber respondido cada escenario.**

---
```

**Step 2: Write answers for all 10 scenarios**

Each answer block must contain:
1. `**Respuesta correcta: X**` (letter only, bold)
2. 2-4 paragraphs of explanation — WHY this answer is correct, the core AWS concept being tested
3. `**Por qué cada incorrecta falla en producción**` section with a bullet or sub-heading per wrong answer
4. `**Exam tip**` blockquote — one mental shortcut or keyword trigger

**Answer summary:**

| # | Correct | Core concept |
|---|---------|--------------|
| 1 | A | SCPs on OU block region even for account admins; IAM boundaries don't apply to all service principals |
| 2 | C | SCPs deny even IAM admin users; IAM policy can be modified by the admin; Config is detective not preventive |
| 3 | B | IDC = single user store, Permission Sets → temporary creds, no long-term keys, centralized de-provisioning |
| 4 | D | CloudTrail = who/what/when (API calls). Config = current state + history. CloudTrail cannot answer "which resources are currently non-compliant" |
| 5 | D | Control Tower = automated baseline + Log Archive + Audit accounts + guardrails. Manual = error-prone, no self-service vending |
| 6 | D | Cross-account KMS: BOTH the KMS key policy (in key account) AND the IAM role policy (in calling account) must grant permission |
| 7 | C | SSM Session Manager + VPC Endpoints = no port 22, no internet, no bastion, IAM-attributed sessions |
| 8 | D | RAM = share resources across accounts without copying. TGW, AMIs, Resolver rules, Subnets all shareable |
| 9 | D | Access Analyzer = resource-based policy analysis for external access. Config Rules check specific properties, not arbitrary trust relationships |
| 10 | C | Permission Boundary = guardrail on what a role/user CAN be granted. iam:PermissionsBoundary condition = enforcement on role creation |

**Step 3: Verify conditions met**

Run through the checklist:
- [ ] Scenarios 1 AND 2: correct answer is SCP/OU, wrong answers include IAM policy
- [ ] Scenario 3: IDC vs IAM Users
- [ ] Scenario 4: CloudTrail vs Config at org level
- [ ] Scenario 5: Control Tower vs manual
- [ ] Scenario 6: KMS AccessDenied in multi-account
- [ ] All answers have: correct answer, explanation, why-wrong section, exam tip

---

## Task 7: Verify and finalize

**Step 1: Check both files exist**
```bash
ls -la security/scenarios/
```

**Step 2: Check questions file has no answers**

Grep for "Respuesta correcta" in questions file — must return 0 matches:
```bash
grep -c "Respuesta correcta" security/scenarios/security-scenarios-sa-associate.md
# Expected: 0
```

**Step 3: Check answers file has all 10 answers**
```bash
grep -c "Respuesta correcta" security/scenarios/security-scenarios-sa-associate-answers.md
# Expected: 10
```

**Step 4: Check cross-links exist in both files**
```bash
grep "answers" security/scenarios/security-scenarios-sa-associate.md
grep "security-scenarios-sa-associate.md" security/scenarios/security-scenarios-sa-associate-answers.md
```

**Step 5: Check mandatory conditions**
```bash
# SCP/OU: scenarios 1 and 2 must mention SCP as correct answer
grep -A2 "Escenario 1\|Escenario 2" security/scenarios/security-scenarios-sa-associate-answers.md | grep "Respuesta correcta"
```

---

## Execution Notes

- Each scenario question: ~400-600 words (business problem + requirements + 4 options)
- Each answer: ~400-600 words (explanation + wrong analysis + exam tip)
- Total estimated content: ~8,000-10,000 words across both files
- Write questions file first (all 10), then answers file (all 10)
- Do not put any answer hints in the questions file
