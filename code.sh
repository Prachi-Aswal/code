CIDR=10.0.0.0/24
aws ec2 create-vpc --cidr-block $CIDR > aws_output.txt
cat aws_output.txt
vpcid=`egrep VpcId aws_output.txt | cut -d":" -f2 | sed 's/"//g' | sed 's/,//g' | cut -d" " -f2`
CIDRPublic=10.0.0.0/25
CIDRPrivate=10.0.0.128/25
aws ec2 create-tags \
  --resources "$vpcid" \
  --tags Key=Name,Value="newvpc"

aws ec2 create-subnet --vpc-id $vpcid --cidr-block $CIDRPublic --availability-zone ap-south-1b > aws_output.txt
cat aws_output.txt
pubsubnetid=`egrep SubnetId aws_output.txt | cut -d":" -f2 | sed 's/"//g' | sed 's/,//g' | cut -d" " -f2`
aws ec2 create-subnet --vpc-id $vpcid --cidr-block $CIDRPrivate --availability-zone ap-south-1a  > aws_output.txt
cat aws_output.txt
aws ec2 create-tags \
  --resources "$pubsubnetid" \
  --tags Key=Name,Value="public_subnet"

privsubnetid=`egrep SubnetId aws_output.txt | cut -d":" -f2 | sed 's/"//g' | sed 's/,//g' | cut -d" " -f2`
aws ec2 create-internet-gateway > aws_output.txt
cat aws_output.txt
aws ec2 create-tags \
  --resources "$privsubnetid" \
  --tags Key=Name,Value="private_subnet"

IGW=`egrep InternetGatewayId aws_output.txt | cut -d":" -f2 | sed 's/"//g' | sed 's/,//g' | cut -d" " -f2`
aws ec2 attach-internet-gateway --vpc-id $vpcid --internet-gateway-id $IGW
aws ec2 create-route-table --vpc-id $vpcid > aws_output.txt
cat aws_output.txt
aws ec2 create-tags \
  --resources "$IGW" \
  --tags Key=Name,Value="IGW"

RoutePublic=`egrep RouteTableId aws_output.txt | cut -d":" -f2 | sed 's/"//g' | sed 's/,//g' | cut -d" " -f2`
aws ec2 create-route-table --vpc-id $vpcid > aws_output.txt
cat aws_output.txt
RoutePrivate=`egrep RouteTableId aws_output.txt | cut -d":" -f2 | sed 's/"//g' | sed 's/,//g' | cut -d" " -f2`
aws ec2 associate-route-table --subnet-id $pubsubnetid --route-table-id $RoutePublic
aws ec2 associate-route-table --subnet-id $privsubnetid --route-table-id $RoutePrivate
aws ec2 modify-subnet-attribute --subnet-id $pubsubnetid --map-public-ip-on-launch
aws ec2 create-route --route-table-id $RoutePublic --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW
aws ec2 allocate-address  > aws_output.txt
cat aws_output.txt
EIP=`egrep AllocationId aws_output.txt | cut -d":" -f2 | sed 's/"//g' | sed 's/,//g' | cut -d" " -f2`

sleep 10

echo "Creating Security Group for NAT instance"
aws ec2 create-security-group --group-name Natsecurity --description "My security group" --vpc-id "$vpcid"  > aws_output.txt
SGNat=`egrep GroupId aws_output.txt | cut -d":" -f2 | sed 's/"//g' | sed 's/,//g' | cut -d" " -f2`
aws ec2 authorize-security-group-ingress \
    --group-id $SGNat \
    --ip-permissions IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges='[{CidrIp='$CIDRPublic'}]'

aws ec2 authorize-security-group-ingress \
    --group-id $SGNat \
    --ip-permissions IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges='[{CidrIp= '$CIDRPrivate' }]'


aws ec2 authorize-security-group-ingress \
    --group-id $SGNat  \
    --ip-permissions IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges='[{CidrIp= '$CIDRPrivate' }]'

aws ec2 authorize-security-group-ingress \
    --group-id $SGNat  \
    --ip-permissions IpProtocol=icmp,FromPort=-1,ToPort=-1,IpRanges='[{CidrIp= 0.0.0.0/0}]'

aws ec2 authorize-security-group-egress --group-id $SGNat --ip-permissions IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges='[{CidrIp=0.0.0.0/0}]'
aws ec2 authorize-security-group-egress --group-id $SGNat --ip-permissions IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges='[{CidrIp=0.0.0.0/0}]'
aws ec2 authorize-security-group-egress --group-id $SGNat --ip-permissions IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges='[{CidrIp=0.0.0.0/0}]'
aws ec2 authorize-security-group-egress --group-id $SGNat --ip-permissions IpProtocol=icmp,FromPort=-1,ToPort=-1,IpRanges='[{CidrIp= '$CIDRPrivate'}]'

aws ec2 run-instances --image-id ami-00999044593c895de --count 1 --instance-type t2.micro --key-name linuxkey --subnet-id $pubsubnetid --security-group-ids $SGNat >aws_output.txt
cat aws_output.txt

NAT=`egrep InstanceId aws_output.txt | cut -d":" -f2 | sed 's/"//g' | sed 's/,//g' | cut -d" " -f2`
echo "waiting for NAT instance"
aws ec2 wait system-status-ok \
    --instance-ids $NAT

aws ec2 modify-instance-attribute --instance-id $NAT --no-source-dest-check
aws ec2 associate-address --instance-id $NAT --allocation-id $EIP > aws_output.txt
cat aws_output.txt
aws ec2 create-route --route-table-id $RoutePrivate --destination-cidr-block 0.0.0.0/0 --instance-id $NAT

MYIP=`curl -s http://whatismyip.akamai.com/`
echo "creating security groups for public subnet"
aws ec2 create-security-group --group-name Pubsecurity --description "Public security group" --vpc-id $vpcid > aws_output.txt
SGPub=`egrep GroupId aws_output.txt | cut -d":" -f2 | sed 's/"//g' | sed 's/,//g' | cut -d" " -f2`

aws ec2 authorize-security-group-ingress \
    --group-id $SGPub \
    --ip-permissions IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges='[{CidrIp='$MYIP/32'}]'

aws ec2 authorize-security-group-ingress \
    --group-id $SGPub  \
    --ip-permissions IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges='[{CidrIp=0.0.0.0/0}]'

aws ec2 authorize-security-group-ingress \
    --group-id $SGPub \
    --ip-permissions IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges='[{CidrIp=0.0.0.0/0}]'

aws ec2 run-instances --image-id ami-0af25d0df86db00c1 --count 1 --instance-type t2.micro --key-name linuxkey --subnet-id $pubsubnetid --security-group-ids $SGPub --user-data file://user.sh > aws_output.txt
cat aws_output.txt
pubins=`egrep InstanceId  aws_output.txt | cut -d":" -f2 | sed 's/"//g' | sed 's/,//g' | cut -d" " -f2`

aws ec2 create-tags \
  --resources "$pubins" \
  --tags Key=Name,Value="public_ins"
aws ec2 allocate-address  > aws_output.txt
cat aws_output.txt

eip=`egrep AllocationId aws_output.txt | cut -d":" -f2 | sed 's/"//g' | sed 's/,//g' | cut -d" " -f2`

aws ec2 wait system-status-ok \
    --instance-ids $pubins

aws ec2 associate-address --instance-id $pubins --allocation-id $eip > aws_output.txt

echo "creating private instance security group"
aws ec2 create-security-group --group-name Prvsecurity --description "Private security group" --vpc-id $vpcid > aws_output.txt
SGPrv=`egrep GroupId aws_output.txt | cut -d":" -f2 | sed 's/"//g' | sed 's/,//g' | cut -d" " -f2`
aws ec2 authorize-security-group-ingress \
    --group-id $SGPrv \
    --ip-permissions IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges='[{CidrIp= 10.0.0.0/25}]'


aws ec2 run-instances --image-id ami-0af25d0df86db00c1 --count 1 --instance-type t2.micro --key-name linuxkey --subnet-id $privsubnetid --security-group-ids $SGPrv  --user-data file://tom.sh > aws_output.txt
cat aws_output.txt
privins=`egrep InstanceId aws_output.txt | cut -d":" -f2 | sed 's/"//g' | sed 's/,//g' | cut -d" " -f2`
aws ec2 create-tags \
  --resources "$privins" \
  --tags Key=Name,Value="private_ins"

aws ec2 wait system-status-ok \
    --instance-ids $privins
