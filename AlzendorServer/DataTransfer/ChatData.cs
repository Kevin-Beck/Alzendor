using System;
using System.Collections.Generic;
using System.Text;

namespace AlzendorServer.DataTransfer
{
    public class ChatData
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
