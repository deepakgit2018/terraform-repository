# Defining provider (e.g., AWS) , this has been defined as part of separate provider file with sample code below
/*
provider "aws" {
  region     = "us-east-1"
  access_key = "TestKey1"
  secret_key = "TestSecret1"
}
*/

# Create VPC , us-east-1 has been taken for this excercise

resource "aws_vpc" "dkvpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags = {
    Name = "3-tier-vpc"
  }
}

# Create Internet gateway for the vpc

resource "aws_internet_gateway" "dkigw" {
  vpc_id = aws_vpc.dkvpc.id
  tags = {
    Name = "dk-igw"
  }
}

# Create EIP for NAT gateways

resource "aws_eip" "natgw-eip" {
  count      = 3
  domain     = "vpc"
  depends_on = [aws_internet_gateway.dkigw]
  tags = {
    Name = "EIP_for_NAT_${count.index}"
  }
}

# Create 1 NAT gateway for each of the public subnets across each AZ

resource "aws_nat_gateway" "dknat" {
  count         = 3
  allocation_id = aws_eip.natgw-eip[count.index].id
  subnet_id     = element(aws_subnet.web[*].id, count.index)
  tags = {
    Name = "dk-NAT"
  }
}

# Create 3 subnets in all layers across each AZ

# Subnets for Web layer
resource "aws_subnet" "web" {
  count                   = 3
  vpc_id                  = aws_vpc.dkvpc.id
  cidr_block              = "10.0.1.${count.index * 32}/27"
  availability_zone       = element(["us-east-1a", "us-east-1b", "us-east-1c"], count.index)
  map_public_ip_on_launch = true
  tags = {
    Name = "web-${count.index}"
  }
}

# Subnets for App layer
resource "aws_subnet" "app" {
  count             = 3
  vpc_id            = aws_vpc.dkvpc.id
  cidr_block        = "10.0.2.${count.index * 32}/27"
  availability_zone = element(["us-east-1a", "us-east-1b", "us-east-1c"], count.index)
  tags = {
    Name = "app-${count.index}"
  }
}

# Subnets for DB layer(Dummy subnets , not creating DB resources as part of this excercise to avoid incurring cost)
resource "aws_subnet" "db" {
  count             = 3
  vpc_id            = aws_vpc.dkvpc.id
  cidr_block        = "10.0.3.${count.index * 32}/27"
  availability_zone = element(["us-east-1a", "us-east-1b", "us-east-1c"], count.index)
  tags = {
    Name = "db-${count.index}"
  }
}

# Create route table for each layer

resource "aws_route_table" "web-rt" {
  vpc_id = aws_vpc.dkvpc.id
  tags = {
    Name = "web-rt"
  }
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.dkigw.id
  }
}

resource "aws_route_table" "app-rt" {
  vpc_id = aws_vpc.dkvpc.id
  count  = 3
  tags = {
    Name = "three-tier-app-rt"
  }
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = element(aws_nat_gateway.dknat[*].id, count.index)
  }
}

resource "aws_route_table_association" "web" {
  count          = 3
  subnet_id      = element(aws_subnet.web[*].id, count.index)
  route_table_id = element(aws_route_table.web-rt[*].id, count.index)
}

resource "aws_route_table_association" "app" {
  count          = 3
  subnet_id      = element(aws_subnet.app[*].id, count.index)
  route_table_id = element(aws_route_table.app-rt[*].id, count.index)
}

# Create one Security group for web layer (Load balancer)
resource "aws_security_group" "alb-sg" {
  name   = "web security group"
  vpc_id = aws_vpc.dkvpc.id
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
#Create Security group for app layer
resource "aws_security_group" "app-sg" {
  name   = "app security group"
  vpc_id = aws_vpc.dkvpc.id
  ingress {
    description     = "Allow http request from Load Balancer"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = ["${aws_security_group.alb-sg.id}"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

#Create EC2 instance for App layer  (We are using EC2 here to host the website)

resource "aws_instance" "app" {
  count                  = 3
  ami                    = var.ami_id
  instance_type          = var.instance_size
  subnet_id              = element(aws_subnet.app[*].id, count.index)
  vpc_security_group_ids = [aws_security_group.app-sg.id]
  tags = {
    name = "app-${count.index}"
  }
  associate_public_ip_address = false
  user_data                   = <<EOF
  #!/bin/bash
yum update -y
yum install -y httpd.x86_64
systemctl restart httpd.service
systemctl enable httpd.service
echo "Hello World! from $(hostname -f)" > /var/www/html/index.html
sudo yum install firewalld
systemctl start firewalld
firewall-cmd --zone=public --add-port=80/tcp --permanent
firewall-cmd --reload
systemctl enable firewalld
EOF
}

#Create Public ALB for accessing the website hosted in backend EC2 instances
resource "aws_lb" "dkalb" {
  name               = "dk-alb"
  internal           = false
  load_balancer_type = "application"
  subnets            = aws_subnet.web[*].id
  security_groups    = [aws_security_group.alb-sg.id]

  enable_deletion_protection       = false
  enable_cross_zone_load_balancing = true
}

# Create Target Group
resource "aws_lb_target_group" "alb-tg" {
  name        = "alb-target-group"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = aws_vpc.dkvpc.id
  target_type = "instance"
}

# Register instances with target group
resource "aws_lb_target_group_attachment" "target_group_attachment" {
  count            = length(aws_instance.app)
  target_group_arn = aws_lb_target_group.alb-tg.arn
  target_id        = aws_instance.app[count.index].id
  port             = 80
}

# Create alb lisener routing the traffic
resource "aws_lb_listener" "alb-listener" {
  load_balancer_arn = aws_lb.dkalb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.alb-tg.arn
  }
}

# Create S3 bucket (No use in this excercise but it is mentioned in diagram hence created)
resource "aws_s3_bucket" "dk_bucket" {
  bucket = "dkbucket15081988"

  tags = {
    Name        = "DK bucket"
    Environment = "Prod"
  }
}