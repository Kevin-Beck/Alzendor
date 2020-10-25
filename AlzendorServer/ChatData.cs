using System;
using System.Collections.Generic;
using System.Text;

namespace AlzendorServer
{
    public class ChatData
    {
        public string Channel {get; set;}
        public string Sender { get; set; }
        public string Message { get; set; }

        public ChatData(string channel, string sender, string message)
        {
            Channel = channel;
            Sender = sender;
            Message = message;
        }
    }
}
