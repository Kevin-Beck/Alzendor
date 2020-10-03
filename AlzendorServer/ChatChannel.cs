﻿using Alzendor.Core.Utilities.Actions;
using System.Collections.Generic;

namespace Alzendor.Server
{
    class ChatChannel : ServerObject
    {
        public string ChannelName { get; set; }
        public Queue<ChatData> feed = new Queue<ChatData>();

        public void AddMessage(MessageAction message)
        {
            ChatData newChatLine = new ChatData(message.Name, message.Sender, message.receiver, message.Message);
            feed.Enqueue(newChatLine);
       //     foreach(string sub in this.subscribers)
       //     {
       //         // for each of my subscribers (these will be clientConnections i think
       //         // add this piece of data to their return data value
       //     }
        }
    }
}
