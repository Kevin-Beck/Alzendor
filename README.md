# Alzendor - AWS
The purpose of this project is to explore different elements of AWS and Redis as well as C# networking using sockets. AWS EC2 instance of a server which each connected to a single scalable instance of Redis running on another ec2 instance. The servers would manage the connection for each client and pass relevant data into the redis game state. The redis instance managed the 'game' and would use its pub sub system to message all relevant parties when an event occured.

The client passes action objects into a server which vets the input and decides what relevant into to pass into the game state on redis. This hop allowed for an additional layer between the client and the redis instance. Each server would reject known bad/illegal inputs and malformed input objects which allowed the redis instance to work within the AWS security group and only communicate with known servers using their own faster/smaller data objects. The input would be parsed and broken down by the servers and then only the smallest most relevant data would be passed into the redis game state data storage. This triggered response events which would be sent back out to any number of servers.

Server 1 would have client a, b, c. Each would log in and connect to the server after being authorized by the server the connection was linked to the redis instance.
Server 2 would have client x, y, z. And other servers would have other clients.

If client a and z 'walked' into room 1, they would subscribe to that room. If client b then walked into that room. A message would be sent to client a and z that says "Player b has entered the room". Note that the clients a and z would be on separate servers, but the connection was managed by redis to know which server to communicate the directions to. Redis would send the message to Server1:ClientA and Server2:ClientZ in order for those clients to recieve the message.

# Scaling
This method allowed for a single point of truth, the redis instance, and that instance could be scaled up. When a certain level of scaling was reached, redis can be clustered which can allow 'infinite' growth.

AWS is capable of spinning up new dockerized 'servers' in new instances, each which wake up and connect to the redis instance. Once a certain threshold is reach on this server, a new one is created which is then ready to accept client connections.

# Issues
A lack of nuance is that client connections simply reach out to a single entity and are connected. There is no regionality built into the system and it does not use any different regions in AWS to help with latency issues. A person connecting in China could be on the same server connection as someone in the US. This aspect of networking was not a focal point of the project so I simply ignored this aspect. Based on my reading the current structure could be scaled up to make use of other load balancing and region balancing tools within AWS.


Also this is not a robust way to do a networking system. Its the absolute bare necessity. If you were to look to make something similar you'd be better off just https://github.com/vis2k/Telepathy as it has everything required with all the flexibility. 


This project overall was a great way to learn about AWS, C# socket networking, Jenkins and Docker stuff.



# Quick Start Guide:
Download and Install:
- [Visual Studio 2019](https://visualstudio.microsoft.com/downloads/)
- [VS Code (suggested)](https://visualstudio.microsoft.com/downloads/)
- [Docker for Desktop](https://www.docker.com/products/docker-desktop)
- [Git for Windows (including bash)](https://gitforwindows.org/)
- [PuTTy(suggested)](https://www.putty.org/)

