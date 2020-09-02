using System;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using AlzendorCore.Utilities.Logger;

namespace Alzendor.Server
{
    public class ClientConnection
    {
        Socket clientSocket;
        string clientNumber;
        ILogger myLogger;
        public ClientConnection(ILogger logger)
        {
            myLogger = logger;
        }
        public void StartClient(Socket inClientSocket, string inClientNumber)
        {
            clientSocket = inClientSocket;
            clientNumber = inClientNumber;
            Thread ctThread = new Thread(DoChat);
            ctThread.Start();
        }
        private void DoChat()
        {
            byte[] bytesFrom;
            int requestCounter = 0;
            bool connected = true;

            while (connected)
            {
                try
                {
                    requestCounter++;
                    bytesFrom = new byte[1024];
                    int bytesRec = clientSocket.Receive(bytesFrom);
                    string dataFromClient = Encoding.ASCII.GetString(bytesFrom);
                    myLogger.Log(LogLevel.Info, $">> From client {clientNumber}: {dataFromClient}");


                    // string myRequestCount = Convert.ToString(requestCounter);
                    string serverResponse = "Server Recieved:\n" + dataFromClient + "\nfrom client: " + clientNumber;
                    byte[] sendBytes = Encoding.ASCII.GetBytes(serverResponse);
                    clientSocket.Send(sendBytes);
                }
                catch (SocketException)
                {
                    myLogger.Log(LogLevel.Info, $">> client({clientNumber}) disconnected");
                    connected = false;
                }
                catch (Exception exception)
                {
                    myLogger.Log(LogLevel.Error, $">> client({clientNumber}) ERROR: {exception.Message}");
                    connected = false;
                }
            }
        }
    }
}
