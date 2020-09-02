using System;
using System.Net;
using System.Net.Sockets;
using System.Text;
using AlzendorCore.Utilities.Logger;
using System.IO;
using Newtonsoft.Json;
using AlzendorCore.Utilities.DataTransfer;
// Client app is the one sending messages to a Server/listener.   
// Both listener and client can send messages back and forth once a   
// communication is established.  
public class Client
{
    public static int Main(String[] args)
    {
        ILogger logger = new LocalFileLogger();
        StartClient(logger);
        return 0;
    }

    public static void StartClient(ILogger logger)
    {
        byte[] bytes = new byte[1024];

        try
        {
            IPHostEntry host = Dns.GetHostEntry("ec2-3-133-100-129.us-east-2.compute.amazonaws.com");
            IPAddress ipAddress = host.AddressList[0];
            IPEndPoint remoteEP = new IPEndPoint(ipAddress, 11000);

            Socket sender = new Socket(ipAddress.AddressFamily, SocketType.Stream, ProtocolType.Tcp);

            try
            {
                logger.Log(LogLevel.Info, $"Trying to connect to : {ipAddress.ToString()}");
                sender.Connect(remoteEP);

                logger.Log(LogLevel.Info, $"Socket connected to {sender.RemoteEndPoint.ToString()}");
                InputManager inputManager = new InputManager();
                while (true)
                {
                    // READ IN DATA FROM USER
                    string input = Console.ReadLine().ToString();
                    // PASS INPUT INTO MANAGER TO GET ACTION
                    var action = inputManager.ParseActionFromText("Morek", input);
                    // ENCODE ACTION
                    var serializedAction = JsonConvert.SerializeObject(action, Formatting.Indented);
                    // SEND AS BYTE ARRAY
                    byte[] msg = Encoding.ASCII.GetBytes(serializedAction.ToCharArray());

                    int bytesSent = sender.Send(msg);

                    int bytesRec = sender.Receive(bytes);
                    logger.Log(LogLevel.Info, "Recieved: " + Encoding.ASCII.GetString(bytes, 0, bytesRec));
                }
            }
            catch (ArgumentNullException argumentNullException)
            {
                logger.Log(LogLevel.Error, $"ArgumentNullException : {argumentNullException.ToString()}");
            }
            catch (SocketException socketException)
            {
                Console.WriteLine($"SocketException : {socketException.ToString()}");
            }
            catch (Exception exception)
            {
                Console.WriteLine($"Unexpected exception : {exception.ToString()}");
            }
            finally
            {
                sender.Shutdown(SocketShutdown.Both);
                sender.Close();
            }
        }
        catch (Exception exception)
        {
            Console.WriteLine(exception.ToString());
        }
    }
}