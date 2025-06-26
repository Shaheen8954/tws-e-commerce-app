data "aws_ami" "os_image" {
  owners = ["099720109477"]
  most_recent = true
  filter {
    name   = "state"
    values = ["available"]
  }
  filter {
    name = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/*24.04-amd64*"]
  }
}

resource "aws_key_pair" "deployer" {
  key_name   = "terra-automate-key"
  public_key = file("terra-key.pub")
}

resource "aws_default_vpc" "default" {

}

resource "aws_security_group" "allow_user_to_connect" {
  name        = "allow TLS"
  description = "Allow user to connect"
  vpc_id      = aws_default_vpc.default.id
  ingress {
    description = "port 22 allow"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = " allow all outgoing traffic "
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "port 80 allow"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "port 443 allow"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "port 8080 allow"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "mysecurity"
  }
}

resource "aws_instance" "testinstance" {
  ami             = data.aws_ami.os_image.id
  instance_type   = var.instance_type 
  key_name        = aws_key_pair.deployer.key_name
  security_groups = [aws_security_group.allow_user_to_connect.name]
  user_data = file("${path.module}/install_tools.sh")
  tags = {
    Name = "Jenkins-Automate"
  }
  root_block_device {
    volume_size = 20
    volume_type = "gp3"
  }
  
}

resource "local_file" "ansible_inventory" {
  content = <<-EOT
    [jenkins]
    ${aws_instance.testinstance.public_ip}
    
    [jenkins:vars]
    ansible_user=ubuntu
    ansible_ssh_private_key_file=${path.module}/terra-key
  EOT
  filename = "${path.module}/inventory.ini"
}
resource "null_resource" "add_host_to_known_hosts" {
  depends_on = [aws_instance.testinstance, local_file.ansible_inventory]

  provisioner "local-exec" {
    command = <<-EOT
      # Create .ssh directory if it doesn't exist
      mkdir -p ~/.ssh
      chmod 700 ~/.ssh
      
      # Remove any existing entries for this host
      ssh-keygen -R ${aws_instance.testinstance.public_ip}
      
      # Add host to known_hosts
      ssh-keyscan -H ${aws_instance.testinstance.public_ip} >> ~/.ssh/known_hosts
      
      # Set correct permissions for known_hosts
      chmod 600 ~/.ssh/known_hosts
    EOT
  }
}



resource "null_resource" "provision_ansible" {
  depends_on = [
    aws_instance.testinstance,
    local_file.ansible_inventory,
    null_resource.add_host_to_known_hosts
  ]

  provisioner "local-exec" {
    command = <<-EOT
      # Wait for SSH to be available
      echo "Waiting for SSH to be available on ${aws_instance.testinstance.public_ip}..."
      until nc -zv ${aws_instance.testinstance.public_ip} 22; do
        echo "Waiting for SSH..."
        sleep 10
      done
      
      # Test SSH connection
      echo "Testing SSH connection..."
      ssh -i ${path.module}/terra-key -o StrictHostKeyChecking=no ubuntu@${aws_instance.testinstance.public_ip} 'echo "SSH connection successful!"'
      
      # Run Ansible playbook with verbose output
      echo "Running Ansible playbook..."
      ANSIBLE_HOST_KEY_CHECKING=False \
      ansible-playbook \
        -i ${path.module}/inventory.ini \
        --private-key ${path.module}/terra-key \
        -v \
        ${path.module}/setup_tools.yml
      
      echo "Ansible provisioning completed!"
    EOT
    
    environment = {
      ANSIBLE_FORCE_COLOR = "True"
    }
  }
} 