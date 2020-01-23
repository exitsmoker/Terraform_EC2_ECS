provider "aws" {
  region = "ap-northeast-2"
}

data "aws_vpc" "vpc" {
  filter { 
    name = "tag:Name"
    values = ["vpc"]
  }
}

data "aws_subnet" "public" {
  filter { 
    name = "tag:Name"
    values = ["subnet"]
  }
}

data "aws_ami" "ubuntu16" {
  most_recent = true


  /**
   * required and this mean image owners
   * well known owner case is just write such as 'amazon', 'aws-marketplace', and 'microsoft'
   * however for use just ubuntu or centos case is write ubuntu is 099720109477, redhat is 309956199498
   */

  owners = ["099720109477"]
  filter { 
    name = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-xenial-16.04-amd64-server-*"]
  }
  filter { 
    name = "virtualization-type"
    values = ["hvm"]
  }
}

//changed EC2-Access-ECS-Role to ecsInstanceRole
data "aws_iam_role" "ecs_role"{
  name = "ecsInstanceRole"
}

//this role is for task and service
data "aws_iam_role" "task_role" {
  name = "ecsTaskExecutionRole"
}

data "aws_ecs_cluster" "cluster" {
  cluster_name = #your cluster-name
}

/**
 * resource
 */

resource "aws_security_group" "security_group" {
  vpc_id = #your vpc_id
  name = "security_group"
}

resource "aws_security_group_rule" "openssh" {
  type = "ingress"
  from_port = 22
  to_port = 22
  protocol = "tcp"
  security_group_id = aws_security_group.security_group.id
  cidr_blocks = ["0.0.0.0/0"]
}

resource "aws_security_group_rule" "outbound" {
  type = "egress"
  from_port = 0
  to_port = 65535
  security_group_id = aws_security_group.security_group.id
  protocol = "all"
  cidr_blocks = ["0.0.0.0/0"]
}

resource "aws_instance" "ec2_instance" {
  ami                    = data.aws_ami.ubuntu16.id
  subnet_id              = data.aws_subnet.public.id
  availability_zone      = var.azn # need to change
  instance_type          = var.ec2_instance_type_small #instance_type
  iam_instance_profile   = data.aws_iam_role.ecs_role.id
  key_name               = var.key_name #your key_name
  ebs_optimized          = "false"
  source_dest_check      = "false"
  user_data              = file("ecs_data.sh")
  vpc_security_group_ids = [aws_security_group.security_group.id] #your security_group
  root_block_device      {
    volume_type           = "gp2"
    volume_size           = "30"
    delete_on_termination = "true"
  }
  tags = {
    Name                  = "ec2_instance"
  }
  provisioner "remote-exec" {
    inline = [
      "sudo apt-get install -y docker.io",
      "sudo sh -c 'echo 'net.ipv4.conf.all.route_localnet = 1' >> /etc/sysctl.conf'",
      "sudo sysctl -p /etc/sysctl.conf",
      "sudo iptables -t nat -A PREROUTING -p tcp -d 169.254.170.2 --dport 80 -j DNAT --to-destination 127.0.0.1:51679",
      "sudo iptables -t nat -A OUTPUT -d 169.254.170.2 -p tcp -m tcp --dport 80 -j REDIRECT --to-ports 51679",
      "sudo mkdir /etc/iptables",
      "sudo sh -c 'iptables-save > /etc/iptables/rules.v4'",
      "sudo mkdir -p /etc/ecs && sudo touch /etc/ecs/ecs.config",
      "sudo mkdir -p /var/log/ecs /var/lib/ecs/data",
      "sudo docker run --name ecs-agent --detach=true --restart=on-failure:10 --volume=/var/run:/var/run --volume=/var/log/ecs/:/log --volume=/var/lib/ecs/data:/data --volume=/etc/ecs:/etc/ecs --net=host --env-file=/etc/ecs/ecs.config amazon/amazon-ecs-agent:latest"
    ]

    connection {
      type = "ssh"
      user = "ubuntu"
      host = self.public_ip
      private_key = file("~/workspace/your_private_key.pem")
    }
  }
}

resource "aws_ecs_task_definition" "task_definition" {
  container_definitions    = <<DEFINITION
    [
      {
        "name": "your_container_name_container",
        "hostname": "host_name",
        "image": "The docker image you want to use",
        "cpu": 512,
        "memory": 512,
        "portMappings": [
          {
            "hostPort": 7001,
            "containerPort": 7001,
            "protocol": "tcp"
          }
        ],
        "essential": true,
        "environment" : [
          { "name" : "If_your_image_need_env_for_example_PORT", "value" : "7003" }
        ]
      }
    ]
    DEFINITION

  execution_role_arn       = data.aws_iam_role.task_role.arn
  family                   = "task_definition"
  network_mode             = "bridge"
  memory                   = "768"
  cpu                      = "768"
  requires_compatibilities = ["EC2"]
  task_role_arn            = data.aws_iam_role.task_role.arn
  #TODO
  #VOLUME
}

resource "aws_ecs_service" "service_definition_" {
  cluster                = data.aws_ecs_cluster.cluster.id                               
  desired_count          = 1                                                         
  launch_type            = "EC2"                                                    
  name                   = "service_definition"                                       
  task_definition        = aws_ecs_task_definition.task_definition.arn       
  placement_constraints {
    type = "memberOf"
    expression = "ec2InstanceId == ${aws_instance.ec2_instance.id}"
  }
}

