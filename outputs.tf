output "website_url" {
  description = "This URL can be used to access the web page"
  value       = "http://${aws_lb.dkalb.dns_name}:80"
}