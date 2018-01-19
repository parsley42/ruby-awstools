This article describes the steps for bootstrapping a new AWS account, starting with root credentials in the console. Note that this guide prescribes the use of MFA (multi-factor authentication) with AWS API keys, to prevent catastrophic use of said keys should they be compromised.

## Installing the AWS CLI
The `ruby-awstools` tool kit is best used in conjunction with the official AWS CLI tool, which provides generic functionality not reproduced in the toolkit. See: [Installing the AWS CLI](http://docs.aws.amazon.com/cli/latest/userguide/installing.html)

## Creating the Administrative User
This guide attempts to encapsulate best practices for managing your AWS account.

1. Log in to the AWS console with your root account
   1. If you have generated API keys for your root account, we recommend you delete them, as having the keys compromised would grant full access to your account
   1. We also recommend configuring MFA access for the root account
1. Locate the IAM service page, and select Users
1. Add a new user with both programmatic and console access
1. Create a new administrators group for the user
1. Instead of selecting a canned policy for the group, create a custom policy using this JSON template that grants full administrative access:
    ```json
    {
        "Version": "2012-10-17",
        "Statement": [
            {
                "Effect": "Allow",
                "Action": "*",
                "Resource": "*"
            }
        ]
    }
    ```
1. Name the new policy and attach it to the group
1. Record the password for the new account, and use the AWS CLI command `aws configure` to record the API keys
1. Log in to the new account, and navigate to IAM
1. Enable MFA on your new administrator account
1. Finally, navigate to Policies and edit the policy you created earlier so that it requires MFA:
    ```json
    {
        "Version": "2012-10-17",
        "Statement": [
            {
                "Effect": "Allow",
                "Action": "*",
                "Resource": "*",
                "Condition": {
                    "Bool": {
                        "aws:MultiFactorAuthPresent": "true"
                    }
                }
            }
        ]
    }
    ```
## Starting a CLI Session for Managing Your Account
The simplest way to start managing your account from the command line is to put a symlink to the `misc/aws-session` script in `$HOME/bin` or `/usr/local/bin`, then run the script using `eval` to set environment variables:
```shell
$ aws ec2 describe-availability-zones

An error occurred (UnauthorizedOperation) when calling the DescribeAvailabilityZones operation:
You are not authorized to perform this operation.
$ eval `aws-session 031375`
$ aws ec2 describe-availability-zones
{
    "AvailabilityZones": [
        {
            "State": "available", 
            "ZoneName": "us-east-1a", 
            "Messages": [], 
            "RegionName": "us-east-1"
        },
...
```
You will then be able to manage your AWS account in the terminal window / tab until you exit the shell.

## Creating the Site Repository and CloudFormation Bucket

