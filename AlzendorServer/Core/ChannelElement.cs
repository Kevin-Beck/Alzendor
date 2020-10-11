using Alzendor.Server.Core.Actions;
using AlzendorCore.Utilities;
using System.Collections.Generic;

namespace Alzendor.Server
{
    public class ChannelElement : GameElement
    {
        public string ChannelName { get; set; }
        public string ChannelOwner { get; set; }
        public bool IsPublic { get; set; } = true;
        public ChannelElement(string channelName, string channelCreator)
        {
            ChannelName = channelName;
            ChannelOwner = channelCreator;
        }
        public void AddMessage(MessageAction message)
        {
            ChatData newChatText = new ChatData(message.Name, message.Sender, message.Receiver, message.Message);
            foreach(ConnectionToClient sub in subscribers)
            {                
                sub.Send(Objectifier.Stringify(newChatText));
           }
        }
    }
}
