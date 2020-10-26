using AlzendorServer.Core.Actions;
using System;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using AlzendorServer.Core.DataTransfer;
using log4net;
using StackExchange.Redis;
using AlzendorServer.Core.Elements;

namespace AlzendorServer
{

    public class ConnectionToClient
    {
        private readonly ILog logger;
        private NetworkStream networkStreamOut;
        private NetworkStream networkStreamIn;
        private readonly ActionProcessor actionProcessor;
        private readonly UserInputInterpretter userInputInterpretter;
        private readonly IDatabase database;
        private readonly ISubscriber subscriber;
        private bool isLoggedIn = false;

        public string ClientID { get; set; } = "unknown ID";

        public ConnectionToClient(ILog log, IDatabase data, ISubscriber sub)
        {
            logger = log;
            database = data;
            subscriber = sub;
            actionProcessor = new ActionProcessor(log, data, sub, this);
            userInputInterpretter = new UserInputInterpretter();
        }
        public void StartClient(Socket clientSocket)
        {
            networkStreamIn = new NetworkStream(clientSocket);
            networkStreamOut = new NetworkStream(clientSocket);

            //TODO create an action for logging in etc, and have the action processor manage it
            while (!isLoggedIn) 
            {
                ClientID = Receive(networkStreamIn);
                logger.Info("ConnectionToClient received name: " + ClientID);
                if (database.KeyExists($"{ElementType.CHANNEL}:" + ClientID))
                {
                    // TODO change this to an object to send back, should be handled by above todo
                    Send("\nName already exist, choose again:");
                }
                else
                {
                    actionProcessor.Process(new CreateAction(ClientID, ElementType.CHANNEL, $"{ClientID}"));
                    isLoggedIn = true;
                    database.SetAdd("loggedIn", ClientID);
                }
            }


            Thread receiveThread = new Thread(ReceiveLoop);
            receiveThread.Start();
        }
        
               
        // TODO create a proper disconnection protocol which will purge game of user and remove their subscriptions
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
        // todo i think this should all be recieving based entirely on the redis pubsub now
        private string Receive(NetworkStream networkStream)
        {
            byte[] bytesFrom = new byte[1024];
            networkStream.Read(bytesFrom);
            string dataFromClient = Encoding.ASCII.GetString(bytesFrom).Replace("\0", string.Empty).Trim();
            logger.Info($"<< From client {ClientID}: {dataFromClient}");
            return dataFromClient;
        }
        public void Send(string data){ 
            byte[] sendBytes = Encoding.ASCII.GetBytes(data.Trim());
            networkStreamOut.Write(sendBytes, 0, sendBytes.Length);
            logger.Info($">> To client {ClientID}: {data}");
        }
    }
}
