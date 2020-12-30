namespace AlzendorServer.DataTransfer
{
    public class ChatData : TransmitData
    {
        public string Recipient {get; set;}
        public string Sender { get; set; }
        public string Message { get; set; }

        public ChatData(string sender, string recipient, string message)
        {
            Recipient = recipient;
            Sender = sender;
            Message = message;
        }
    }
}
