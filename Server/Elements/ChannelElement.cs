using Server.Elements;
using System.Collections.Generic;

namespace Server.Elements
{
    public class ChannelElement : GameElement
    {
        public string ChannelName { get; set; }
        public string ChannelOwner { get; set; }
        public bool IsPrivate { get; set; } = true;
        public ChannelElement(string channelName, string channelCreator, bool isPrivate) : base(ElementType.CHANNEL, channelName)
        {
            ChannelName = channelName;
            ChannelOwner = channelCreator;
            IsPrivate = isPrivate;
        }
    }
}
