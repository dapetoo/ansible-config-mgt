
Installing Ansible
```
sudo apt update
sudo apt install ansible -y
```

Installing Jenkins
```
sudo apt install default-jdk default-jre

curl -fsSL https://pkg.jenkins.io/debian-stable/jenkins.io.key | sudo tee \
  /usr/share/keyrings/jenkins-keyring.asc > /dev/null
echo deb [signed-by=/usr/share/keyrings/jenkins-keyring.asc] \
  https://pkg.jenkins.io/debian-stable binary/ | sudo tee \
  /etc/apt/sources.list.d/jenkins.list > /dev/null
sudo apt-get update
sudo apt-get install jenkins
```

Jenkins WebHook & GitHub Hook

Click on Settings on the project repo
Click on Webhook
Enter the Jenkins server URL and append /github-webhook/ to the URL, select the event types to trigger the webhook

