using System;
using System.Collections.Generic;
using System.Text;

namespace Alzendor.Server
{
    public class ChatData
    {
        public string DataOwner { get; set; }
        public string Channel {get; set;}
        public string Sender { get; set; }
        public string Recipient { get; set; }
        public string Message { get; set; }

        public ChatData(string channel, string sender, string recipient, string message)
        {
            Channel = channel;
            Sender = sender;
            Recipient = recipient;
            Message = message;
        }
    }
}
