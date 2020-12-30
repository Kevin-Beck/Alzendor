using Server.Actions;
using System;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using Server.DataTransfer;
using log4net;
using StackExchange.Redis;
using Server.Elements;
using System.Reflection;
using Core.Utilities;
using System.Linq;
using System.Text.RegularExpressions;

namespace Server.Base
{
    /// <summary>
    /// Connection to client is the object that is created on the server to maintain the connection to the client. It is created by ServerMain each time a new client connects.
    /// </summary>
    public class ConnectionToClient
    {
        private readonly ILog logger = LogManager.GetLogger(MethodBase.GetCurrentMethod().DeclaringType);
        private NetworkStream networkStreamOut;
        private NetworkStream networkStreamIn;
        private readonly ActionProcessor actionProcessor;
        private readonly UserInputInterpretter userInputInterpretter;
        private readonly IDatabase database;
        private LogInStatus logInState = LogInStatus.LoggedOut;

        public string ClientID { get; set; } = "unknown ID";

        public ConnectionToClient(IDatabase data, ISubscriber sub, Socket client)
        {
            database = data;
            actionProcessor = new ActionProcessor(data, sub, this);
            userInputInterpretter = new UserInputInterpretter();
            Thread clientThread = new Thread(() => StartClient(client));
            clientThread.Start();
        }
        private void StartClient(Socket incomingClient)
        {
            networkStreamIn = new NetworkStream(incomingClient);
            networkStreamOut = new NetworkStream(incomingClient);
                        
            logger.Info("Received unknown client");
            while (logInState != LogInStatus.LoggedIn)
            {
                var userLogIn = UserLogIn();
                logInState = userLogIn.logInStatus;
                ClientID = userLogIn.loginName;
            }
            // Actually log the player in

            actionProcessor.Process(new CreateAction(ClientID, ElementType.CHANNEL, $"{ClientID}"));


            logger.Info($"Identified client as {ClientID}");

            Thread receiveThread = new Thread(ReceiveLoop);
            receiveThread.Start();
        }

        private (string loginName, LogInStatus logInStatus) UserLogIn()
        {
            Send(new ChatData(ServerMessageType.Info.ToString(), "new connection", "Enter your character name, or CREATE to make a new character"));

            string choice = Receive(networkStreamIn);
            if (choice.ToLower().Trim() == "create")
            {
                Send(new ChatData(ServerMessageType.Info.ToString(), "new connection", "Choose a character name:"));
                string characterName = Receive(networkStreamIn);
                if (database.KeyExists(actionProcessor.GetNamingConvention(ElementType.USER, characterName.ToLower())))
                {
                    Send(new ChatData(ServerMessageType.Info.ToString(), "new connection", "User already exists, you'll have to choose another name."));
                    return ("unknown", LogInStatus.LoggedOut);
                }
                else
                {
                    Regex regex = new Regex("^[a-zA-Z]+");
                    if (!regex.IsMatch(characterName) || (characterName.Count(c => "aeiouy".Contains(Char.ToLower(c))) < 1) || characterName.Length < 2)
                    {
                        Send(new ChatData(ServerMessageType.Warning.ToString(), "new connection", "Name must contain 2 characters, only letters, 1 being a vowel."));
                        return ("unknown", LogInStatus.LoggedOut);
                    }
                    else
                    {
                        // create new user
                        User user = new User(characterName);

                        database.StringSet(actionProcessor.GetNamingConvention(ElementType.USER, user.CharacterName), Objectifier.Stringify(user));
                        return (user.CharacterName, LogInStatus.LoggedIn);
                    }
                }
            }
            else
            {
                // TODO other side of login
                // find out if the user exists, cause we have a username
                // if it doesnt, go through the process of sorting out 
                return ("TODO", LogInStatus.LoggedIn);
            }
        }
        
               
        // TODO create a proper disconnection protocol which will purge game of user
        // Wrap the send receive and have them throw the errors with connections back to the threads and handle the crashes and self destruct
        private void ReceiveLoop()
        {            
            bool connected = true;
            
            while (connected)
            {
                try
                {
                    var receivedText = Receive(networkStreamIn);
                    var userAction = userInputInterpretter.ParseActionFromText(ClientID, receivedText);
                    actionProcessor.Process(userAction);
                }
                catch (SocketException)
                {
                    logger.Info($">> client({ClientID}) disconnected");
                    connected = false;
                }
                catch (Exception exception)
                {
                    logger.Info("RecieveLoop has crashed");
                    logger.Error($">> client({ClientID}) ERROR: {exception.Message}");
                    connected = false;
                }
            }
        }

        private string Receive(NetworkStream networkStream)
        {
            byte[] bytesFrom = new byte[1024];
            networkStream.Read(bytesFrom);
            string dataFromClient = Encoding.Default.GetString(bytesFrom).Replace("\0", string.Empty).Trim();
            logger.Info($">> From client {ClientID}: {dataFromClient}");
            return dataFromClient;
        }
        public void Send(TransmitData objectData){
            string data = Objectifier.Stringify(objectData);
            byte[] sendBytes = Encoding.Default.GetBytes(data.Trim());
            networkStreamOut.Write(sendBytes, 0, sendBytes.Length);
            logger.Info($"<< To client {ClientID}: {data}");
        }
    }
}
