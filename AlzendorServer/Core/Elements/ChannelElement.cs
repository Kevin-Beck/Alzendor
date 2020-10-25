using AlzendorServer.Core.Actions;
using AlzendorCore.Utilities;
using AlzendorServer.Core.Elements;

namespace AlzendorServer.Elements
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
            ChatData newChatText = new ChatData(message.ElementName, message.Sender, message.Message);
            foreach(ConnectionToClient sub in subscribers)
            {                
                sub.Send(Objectifier.Stringify(newChatText));
           }
        }
    }
}
