# deploy.ps1
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

########## EDIT HERE (환경에 맞게 수정) ##########
$AWS_REGION            = "ap-northeast-2"       # 서울
$ECR_REPO_NAME         = "dorm-scraper"         # ECR 리포 이름
$IMAGE_TAG             = "latest"               # 이미지 태그
$LAMBDA_FUNCTION_NAME  = "kiryong-scraper"      # Lambda 함수 이름

# Lambda 실행 역할 (함수에 연결될 Role)
$CREATE_EXEC_ROLE_IF_NEEDED = $true
$LAMBDA_EXEC_ROLE_NAME      = "LambdaExec_S3Put"

# 함수 리소스/환경변수
$MEMORY_MB   = 1024
$TIMEOUT_SEC = 120
$ENV_VARS = @{
  S3_BUCKET    = "kiryong-menu-csv"   # 미리 생성한 S3 버킷
  S3_PREFIX    = ""
  CSV_NAME     = "output.csv"
  CSV_UTF8_SIG = "1"
}

# (선택) 배포용 Role을 Assume 해서 실행하려면 true 로
$USE_ASSUME_ROLE = $false
$DEPLOY_ROLE_ARN = "arn:aws:iam::381305464439:role/LambdaDeployer"  # 실제 ARN으로 교체
##################################################

function Require-Cmd { param([string]$name)
  if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
    throw "Missing command: $name"
  }
}

function New-TmpFile {
  $p = [System.IO.Path]::GetTempFileName()
  Get-Item $p
}

Write-Host "==> Checking prerequisites..."
Require-Cmd "aws"
Require-Cmd "docker"

# (선택) AssumeRole
if ($USE_ASSUME_ROLE) {
  if ($DEPLOY_ROLE_ARN -like "*381305464439*") {
    throw "Please set a real DEPLOY_ROLE_ARN before USE_ASSUME_ROLE=true."
  }
  Write-Host "==> Assuming role: $DEPLOY_ROLE_ARN"
  $creds = aws sts assume-role --role-arn $DEPLOY_ROLE_ARN --role-session-name DeploySession | ConvertFrom-Json
  $env:AWS_ACCESS_KEY_ID     = $creds.Credentials.AccessKeyId
  $env:AWS_SECRET_ACCESS_KEY = $creds.Credentials.SecretAccessKey
  $env:AWS_SESSION_TOKEN     = $creds.Credentials.SessionToken
}

# 자격증명 확인 (토큰 만료/미로그인 방지)
try {
  aws sts get-caller-identity | Out-Null
} catch {
  throw "AWS credentials are not valid (maybe expired). If you use SSO: 'aws sso login'. If you use assume-role, set USE_ASSUME_ROLE=true."
}

$ACCOUNT_ID = (aws sts get-caller-identity --query Account --output text)
$ECR_BASE   = "$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"
# 콜론(:) 붙는 위치는 반드시 서브식으로!
$IMAGE_URI  = "$ECR_BASE/$($ECR_REPO_NAME):$IMAGE_TAG"

Write-Host "==> Ensure ECR repo '$ECR_REPO_NAME'..."
try {
  aws ecr describe-repositories --repository-names $ECR_REPO_NAME --region $AWS_REGION | Out-Null
  Write-Host "   ECR repo exists."
} catch {
  aws ecr create-repository --repository-name $ECR_REPO_NAME --region $AWS_REGION | Out-Null
  Write-Host "   ECR repo created."
}

Write-Host "==> ECR login..."
$pw = aws ecr get-login-password --region $AWS_REGION
if (-not $pw) { throw "Failed to get ECR password. Credentials may be expired." }
$pw | docker login --username AWS --password-stdin $ECR_BASE
if ($LASTEXITCODE -ne 0) { throw "ECR login failed." }

Write-Host "==> Docker build/tag/push ($IMAGE_URI)..."
docker build -t $IMAGE_URI .
if ($LASTEXITCODE -ne 0) { throw "Docker build failed." }
docker push $IMAGE_URI
if ($LASTEXITCODE -ne 0) { throw "Docker push failed." }

# 실행 역할 준비
$ROLE_ARN = ""
if ($CREATE_EXEC_ROLE_IF_NEEDED) {
  Write-Host "==> Ensure Lambda execution role '$LAMBDA_EXEC_ROLE_NAME'..."
  $roleExists = $true
  try { aws iam get-role --role-name $LAMBDA_EXEC_ROLE_NAME | Out-Null } catch { $roleExists = $false }

  if (-not $roleExists) {
    # Trust policy (Lambda 서비스 신뢰)
    $trust = @"
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Principal": { "Service": "lambda.amazonaws.com" }, "Action": "sts:AssumeRole" }
  ]
}
"@
    $tmpTrust = New-TmpFile
    $trust | Set-Content -LiteralPath $tmpTrust.FullName -NoNewline -Encoding UTF8
    aws iam create-role --role-name $LAMBDA_EXEC_ROLE_NAME --assume-role-policy-document "file://$($tmpTrust.FullName)" | Out-Null

    # CloudWatch Logs 기본 정책 (정확한 ARN 주의)
    aws iam attach-role-policy --role-name $LAMBDA_EXEC_ROLE_NAME `
      --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole | Out-Null

    # (필요 시) S3 쓰기 권한 인라인 정책
    $bucket = $ENV_VARS.S3_BUCKET
    if ($bucket) {
      $s3pol = @"
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Action": ["s3:PutObject","s3:AbortMultipartUpload","s3:ListBucket"],
      "Resource": ["arn:aws:s3:::$bucket","arn:aws:s3:::$bucket/*"] }
  ]
}
"@
      $tmpPol = New-TmpFile
      $s3pol | Set-Content -LiteralPath $tmpPol.FullName -NoNewline -Encoding UTF8
      aws iam put-role-policy --role-name $LAMBDA_EXEC_ROLE_NAME --policy-name "S3CsvWritePolicy" --policy-document "file://$($tmpPol.FullName)" | Out-Null
    }

    Write-Host "   Role created. Waiting for IAM propagation..."
    Start-Sleep -Seconds 10
  } else {
    Write-Host "   Role exists."
  }
  $ROLE_ARN = (aws iam get-role --role-name $LAMBDA_EXEC_ROLE_NAME --query "Role.Arn" --output text)
} else {
  $ROLE_ARN = (aws iam get-role --role-name $LAMBDA_EXEC_ROLE_NAME --query "Role.Arn" --output text)
}

# Lambda 함수 생성/업데이트
Write-Host "==> Create/Update Lambda function '$LAMBDA_FUNCTION_NAME'..."
$fnExists = $true
try { aws lambda get-function --function-name $LAMBDA_FUNCTION_NAME --region $AWS_REGION | Out-Null } catch { $fnExists = $false }

if ($fnExists) {
  aws lambda update-function-code --function-name $LAMBDA_FUNCTION_NAME --image-uri $IMAGE_URI --region $AWS_REGION | Out-Null
  Write-Host "   Updated image."
} else {
  aws lambda create-function `
    --function-name $LAMBDA_FUNCTION_NAME `
    --package-type Image `
    --code ImageUri=$IMAGE_URI `
    --role $ROLE_ARN `
    --timeout $TIMEOUT_SEC `
    --memory-size $MEMORY_MB `
    --region $AWS_REGION | Out-Null
  Write-Host "   Created function."
}

# 환경변수/리소스 설정

# 빈 값은 제거 (원하면 유지해도 되지만, 공백 전달 이슈 예방)
if ($ENV_VARS.ContainsKey('S3_PREFIX') -and [string]::IsNullOrWhiteSpace($ENV_VARS['S3_PREFIX'])) {
  $ENV_VARS.Remove('S3_PREFIX') | Out-Null
}

# JSON을 임시 파일에 쓰고 file:// 로 전달 (따옴표/이스케이프 이슈 회피)
$envObj  = @{ Variables = $ENV_VARS }
$tmpEnv  = New-TmpFile
$envJson = $envObj | ConvertTo-Json -Compress -Depth 5
$envJson | Set-Content -LiteralPath $tmpEnv.FullName -Encoding UTF8 -NoNewline

aws lambda update-function-configuration `
  --function-name $LAMBDA_FUNCTION_NAME `
  --timeout $TIMEOUT_SEC `
  --memory-size $MEMORY_MB `
  --environment file://$($tmpEnv.FullName) `
  --region $AWS_REGION | Out-Null

# 출력 (배열로 만든 뒤 -join)
$fnArn   = (aws lambda get-function --function-name $LAMBDA_FUNCTION_NAME --region $AWS_REGION --query "Configuration.FunctionArn" --output text)
$envList = ($ENV_VARS.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', '

Write-Host ""
Write-Host "==> Done."
Write-Host "Function: $LAMBDA_FUNCTION_NAME"
Write-Host "FunctionArn: $fnArn"
Write-Host "Image: $IMAGE_URI"
Write-Host "Env:   $envList"
