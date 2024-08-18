---
- name: "Fetching Instance Details"
  become: false
  hosts: localhost
  vars:
    region: "ap-south-1"
    asg_name: "ansible-asg"

  tasks:
    - name: "Gathering instance details of ASG {{ asg_name }}"
      amazon.aws.ec2_instance_info:
        region: "{{ region }}"
        filters:
          "tag:aws:autoscaling:groupName": "{{ asg_name }}"
          "tag:Project": "uber"
          "tag:Env": "dev"
          instance-state-name: [ "running"]
      register: aws_instance_details
        
    - name: "Creating dynamic inventory"
      add_host:
        groups: "ags_rolling_instances"
        hostname: "{{ item.public_ip_address  }}"
        ansible_ssh_user: "ec2-user"
        ansible_ssh_host: '{{ item.public_ip_address  }}'
        ansible_ssh_port: "22"
        ansible_ssh_private_key_file: "devops.pem" 
        ansible_ssh_common_args: "-o StrictHostKeyChecking=no"
      with_items: "{{ aws_instance_details.instances }}"  

- name: "Deploying website to {{ asg_name }} instances"
  become: true
  hosts: ags_rolling_instances
  serial: 1
  vars:
    repo_url: https://github.com/sreenidhiramachandran/aws-elb-site.git
    clone_dir: "/var/website/"
    health_check_delay: 25
    httpd_owner: "apache"
    httpd_group: "apache"
    httpd_port: "80"
    httpd_domain: "asg.sreenidhi.tech"
    packages:
      - httpd
      - php
      - git

  tasks:
    - name: "Installing packages"
      yum:
        name: "{{packages}}"
        state: present
      notify:
        - apache-reload
  
    - name: "Creating httpd.conf from httpd.conf.j2 template"
      template:
        src: "./httpd.conf.j2"
        dest: "/etc/httpd/conf/httpd.conf"
      notify:
        - apache-reload

    - name: "Creating Virtualhost from virtualhost.conf.j2 template"
      template:
        src: "./virtualhost.conf.j2"
        dest: "/etc/httpd/conf.d/{{ httpd_domain }}.conf"
        owner: "{{httpd_owner}}"
        group: "{{httpd_group}}"
      notify:
        - apache-reload

    - name: "Creating document root /var/www/html/{{ httpd_domain }}"
      file:
        path: "/var/www/html/{{ httpd_domain }}"
        state: directory
        owner: "{{httpd_owner}}"
        group: "{{httpd_group}}"        
        
    - name: "Creating clone directory {{clone_dir}}"
      file:
        path: "{{clone_dir}}"
        state: directory

    - name: "Clone website contents from {{repo_url}}"
      git:
        repo: "{{ repo_url }}"
        dest: "{{clone_dir}}"
        force: true
      register: clone_status
      notify:
        - apache-restart
        - online-delay

    - name: "off-loading instance {{ ansible_fqdn }}"
      when: clone_status.changed
      service:
        name: httpd
        state: stopped
      notify:
        - apache-restart
        - online-delay
        
    - name: "waiting for connection draining {{ ansible_fqdn }}"
      when: clone_status.changed
      wait_for:
        timeout: "{{ health_check_delay }}"   

    - name: "Copying files to /var/www/html/{{ httpd_domain }}"
      when: clone_status.changed == true
      copy:
        src: "{{clone_dir}}"
        dest: "/var/www/html/{{ httpd_domain }}"
        remote_src: true
        owner: "{{httpd_owner}}"
        group: "{{httpd_group}}"
      notify:
        - apache-restart
        - online-delay

  handlers:
    - name: "apache-restart"
      service:
        name: httpd
        state: restarted
        enabled: true

    - name: "apache-reload"
      service:
        name: httpd
        state: reloaded
        enabled: true 

    - name: "online-delay"
      wait_for:
        timeout: "30"   
