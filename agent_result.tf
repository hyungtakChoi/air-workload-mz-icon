resource "aws_instance" "test" {
  ami = "ami-12345678"
  instance_type = "t3.micro"
}
