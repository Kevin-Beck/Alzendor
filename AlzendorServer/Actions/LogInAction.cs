using AlzendorServer.Elements;
using System;
using System.Collections.Generic;
using System.Text;

namespace AlzendorServer.Actions
{    public class LogInAction : ActionObject
    {
        public LogInStatus CurrentStep { get; set; }
        public string UserDataForStep { get; set; }
        public LogInAction(LogInStatus currentLogInStatus, string dataForStep) : base(dataForStep, ActionType.LOGIN, ElementType.PLAYER, dataForStep, ActionPriority.LOW)
        {
            CurrentStep = currentLogInStatus;
            UserDataForStep = dataForStep;
        }
    }
}
