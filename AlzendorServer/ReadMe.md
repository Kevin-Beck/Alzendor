# ReadMe
## About the project

This project is entirely an exercise in networked game scaling and development. It may accidentally turn into a game, but at its core its an investigation into the issues that come with large scale networked applications.

There are a few things that I wanted to learn about and while it started from a long term dream its now scaling into something more comprehensive. The current primary investigations are listed here in no particular order:

1. Dotnet Core with C#
2. TCP socket programming
3. AWS EC2 instances
4. Docker
5. Git
6. Redis
7. To be continued

## Motivations

I've always loved the game Achaea, a text based MUD. This style of gaming always pulled me in and on the surface it seems simple. I mean how hard can a text based game be to create?

So after 19 years of living on the planet I made my first text based game, before I knew what a class was, before I knew anything about anything code related I spent hours and hours hard coding a little rng game with a basic 4x4 map. The premise was you could walk around and catch a butterfly while trying to avoid a lion roaming in the grass. It was great. It was also terrible. I was missing even a basic understanding of what was needed for creating a program. I started learning unity3d and learned the basics of programming and managed to create a couple games. But everytime I returned to the text based game I hit different walls.

Whether it was threading or networking or even just maintainable code I always hit a wall. 12 years since my first attempt I'm revisiting the project with a Bachelors in Computer Science, a Bachelors in Mathematics and a year of Software Engineering experience. Guess what? Its still hard. But its been a lifelong dream and I will figure it out. Below is the current status of the server.

## Status

The networking is based on TCP sockets and each client passes strings into the server. The protocol for connecting is very basic. A this point simply entering a username is all that is required. Auth and storing user data is not yet implemented.
The server starts and opens a port, if its hosted locally or on an ec2 instance it functions the same, you can pass in the public ip of the server and it sits waiting for a connection.
The server also creates a connection to a redis instance which can also be located at an endpoint or locally.
A user connects to the server and a client connection object is created and spun off onto its own thread. This clientConnection object is a passthrough and filter from the user to the redis database.

[(client)user enters a string] -> "tell alice hello" -> [(Server)User data is interpretted -> MessageAction -> ActionProcessor interacts with redis] <-> [(Redis) manages pubsub and gamestate]

This structure of interacting with redis allows us to spin up any number of instances of the server without needing to pass data between the instances or the users. Everything passes through redis. Because redis is in memory its generally a fast interaction and should be scalable and functional even at high volumes of messages.

Clients will recieve lightweight (as lightweight as possible) objects from the server that they will also need to manage/render appropriately. I'm hoping to create a UI to go along with the text based components. This will allow a lot of flexibility for the client software as it can choose what to render and where. Basic interfaces can just spew out the objects into a terminal, while more involved clients can render data to the screen by drawing objects/maps etc.

## Conceptual Parts for the Codebase

Within the server there are Actions and Elements, then there is the UserInterpretter and the action processor. The goal is to contain everything into this framework.

To create an action from the string the user sends there is a lot of parsing of the string. There are no conventions at this point, but the following are the current command formats:
Tell <player/channel> <message>
Create <channel> <channelName>
Subscribe to <channel>

By parsing out the relevant data we create ActionObjects, which are then passed to the Action Processor where the "What and How" happens. This is where the checks and data gathering occurs. If a player sends a message to a channel, we need to determine if that channel exists, if the player is allowed to talk on that channel etc. This all happens in the action processor. Then to send this data onward to all the relevant parties we do .. nothing. Well we publish the data to the relevant channels on redis and redis lets everyone know. This is another reason using redis was picked as the datastore. The pubsub is super lightweight and simple to use, so it handles all the data sending and the actionprocessor interacts with users through this pubsub model.



## TODO

The code is littered with todos. This is how I keep my head in the right place and leave notes about what my thought process was or is. It also helps me pick up where I left off day after day. Its not pretty but its pretty hard to keep track of ideas while you're in the middle of another solve.

