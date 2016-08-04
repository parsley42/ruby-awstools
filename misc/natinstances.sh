#!/bin/bash

if [ -n "$1" ]
then
	for REGION in us-east-1 us-west-1 us-west-2 eu-west-1 eu-central-1 sa-east-1 ap-southeast-1 ap-southeast-2 ap-northeast-1
	do
		AMIID=$(aws ec2 describe-images --region=$REGION --filter Name="owner-alias",Values="amazon" --filter Name="name",Values="amzn-ami-vpc-nat-hvm-$1*ebs" --query 'Images[*].ImageId' --output=text)
		echo "\"$REGION\" : { \"AMI\": \"$AMIID\" },"
	done
else
	aws ec2 describe-images --region=us-east-1 --filter Name="owner-alias",Values="amazon" --filter Name="name",Values="amzn-ami-vpc-nat-hvm*ebs" --query 'Images[*].{Name:Name,ID:ImageId}' --output=table
fi
