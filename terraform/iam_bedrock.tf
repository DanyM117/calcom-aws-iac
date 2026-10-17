# 1. Documento de política de confianza para que EC2 asuma el rol
data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

# 2. Rol IAM para la instancia EC2
resource "aws_iam_role" "calcom_bedrock_role" {
  name               = "calcom-ec2-bedrock-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json

  tags = {
    Name = "calcom-ec2-bedrock-role"
  }
}

# 3. Política de mínimo privilegio para invocar Claude Haiku 4.5 en Bedrock
data "aws_iam_policy_document" "bedrock_invoke" {
  statement {
    sid    = "AllowClaudeHaiku45Invoke"
    effect = "Allow"
    actions = [
      "bedrock:InvokeModel",
      "bedrock:InvokeModelWithResponseStream"
    ]
    resources = [
      # Permite el Inference Profile de US y los Foundation Models subyacentes de Haiku 4.5
      "arn:aws:bedrock:us-*:*:inference-profile/us.anthropic.claude-haiku-4-5-*",
      "arn:aws:bedrock:us-*::foundation-model/anthropic.claude-haiku-4-5-*"
    ]
  }
}

resource "aws_iam_role_policy" "bedrock_invoke_policy" {
  name   = "calcom-bedrock-haiku-policy"
  role   = aws_iam_role.calcom_bedrock_role.id
  policy = data.aws_iam_policy_document.bedrock_invoke.json
}

# 4. Instance Profile que se adjunta a la instancia EC2
resource "aws_iam_instance_profile" "calcom_profile" {
  name = "calcom-ec2-instance-profile"
  role = aws_iam_role.calcom_bedrock_role.name
}