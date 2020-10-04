using Alzendor.Server.Core.Actions;
using Alzendor.Core.Utilities.Logger;
using System;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using Alzendor.Server.Core.DataTransfer;

namespace Alzendor.Server
{

    public class ConnectionToClient
    {
        private readonly ILogger logger;
        private NetworkStream networkStreamOut;
        private NetworkStream networkStreamIn;
        private ActionProcessor actionProcessor;
        private UserInputInterpretter userInputInterpretter;

        public string ClientID { get; set; } = "unknown ID";

        public ConnectionToClient(ILogger inlogger, ActionProcessor processor, UserInputInterpretter interpretter)
        {
            logger = inlogger;
            actionProcessor = processor;
            userInputInterpretter = interpretter;
        }
        public void StartClient(Socket inClientSocket)
        {
            networkStreamIn = new NetworkStream(inClientSocket);
            Thread receiveThread = new Thread(ReceiveLoop);
            receiveThread.Start();
            CreateSendConnection(inClientSocket.RemoteEndPoint as IPEndPoint);
        }
        private void CreateSendConnection(IPEndPoint endPoint)
        {
            try
            {
                // Create the socket that hooks back into the client
                IPHostEntry serverHost = Dns.GetHostEntry(endPoint.Address);
                IPAddress serverIpAddress = serverHost.AddressList[0];
                IPEndPoint remoteEP = new IPEndPoint(endPoint.Address, 11001);
                Socket sendToClientSocket = new Socket(serverIpAddress.AddressFamily, SocketType.Stream, ProtocolType.Tcp);

                logger.Log(LogLevel.Info, $"Trying to connect to: {serverIpAddress.ToString()}");
                sendToClientSocket.Connect(remoteEP);
                logger.Log(LogLevel.Info, $"Socket connected to: {sendToClientSocket.RemoteEndPoint.ToString()}");

                networkStreamOut = new NetworkStream(sendToClientSocket);
            }
            catch (Exception exception)
            {
                logger.Log(LogLevel.Error, exception.Message);
            }
        }
        
        private void ReceiveLoop()
        {            
            bool connected = true;
            ClientID = Receive(networkStreamIn);

            logger.Log(LogLevel.Info, "ConnectionToClient has: " + ClientID);
            while (connected)
            {
                try
                {
                    var receivedText = Receive(networkStreamIn);
                    var output = userInputInterpretter.ParseActionFromText(ClientID, receivedText);
                    actionProcessor.Add(output);
                }
                catch (SocketException)
                {
                    logger.Log(LogLevel.Info, $">> client({ClientID}) disconnected");
                    connected = false;
                }
                catch (Exception exception)
                {
                    logger.Log(LogLevel.Error, $">> client({ClientID}) ERROR: {exception.Message}");
                    connected = false;
                }
            }
        }
        private string Receive(NetworkStream networkStream)
        {
            byte[] bytesFrom = new byte[1024];
            networkStream.Read(bytesFrom);
            string dataFromClient = Encoding.ASCII.GetString(bytesFrom);
            logger.Log(LogLevel.Info, $"<< From client {ClientID}: {dataFromClient}");
            return dataFromClient;
        }
        public void Send(string data){ 
            byte[] sendBytes = Encoding.ASCII.GetBytes(data);
            networkStreamOut.Write(sendBytes, 0, sendBytes.Length);
            logger.Log(LogLevel.Info, $">> To client {ClientID}: {data}");
        }
    }
}
