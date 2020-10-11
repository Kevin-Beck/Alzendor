using Alzendor.Server.Core.Actions;
using System;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using Alzendor.Server.Core.DataTransfer;
using log4net;

namespace Alzendor.Server
{

    public class ConnectionToClient
    {
        private readonly ILog logger;
        private NetworkStream networkStreamOut;
        private NetworkStream networkStreamIn;
        private readonly ActionProcessor actionProcessor;
        private readonly UserInputInterpretter userInputInterpretter;

        public string ClientID { get; set; } = "unknown ID";

        public ConnectionToClient(ILog inlogger, ActionProcessor processor, UserInputInterpretter interpretter)
        {
            logger = inlogger;
            actionProcessor = processor;
            userInputInterpretter = interpretter;
        }
        public void StartClient(Socket clientSocket)
        {
            networkStreamIn = new NetworkStream(clientSocket);
            networkStreamOut = new NetworkStream(clientSocket);

            ClientID = Receive(networkStreamIn);
            logger.Info("ConnectionToClient has: " + ClientID);

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
                    actionProcessor.Add(userAction);
                }
                catch (SocketException)
                {
                    logger.Info($">> client({ClientID}) disconnected");
                    connected = false;
                }
                catch (Exception exception)
                {
                    logger.Error($">> client({ClientID}) ERROR: {exception.Message}");
                    connected = false;
                }
            }
        }
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

        private void SelfDestruct()
        {
            networkStreamIn.Close();
            networkStreamOut.Close();
            networkStreamIn.Dispose();
            networkStreamOut.Dispose();
            actionProcessor.RemoveUser(ClientID);
        }
    }
}
